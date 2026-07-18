import Foundation
import CoreLocation
import MapKit
import Network
import CannonballCore

public enum TripError: LocalizedError {
    case noCarLocation, noRoute

    public var errorDescription: String? {
        switch self {
        case .noCarLocation: "No car location yet. Check the Tessie connection in Settings."
        case .noRoute: "Couldn't route to that destination."
        }
    }
}

/// Run configuration. Real secrets live in the keychain / an untracked
/// Secrets.plist — these are the wiring points, never committed values.
public struct RunConfig: Sendable {
    public var tessieVIN: String
    public var tessieToken: String
    public var pandaEndpointHost: String = "192.168.4.1"
    public var westbound = true
    public init(tessieVIN: String, tessieToken: String) {
        self.tessieVIN = tessieVIN; self.tessieToken = tessieToken
    }
}

/// Composition root: constructs and wires every subsystem, owns the replan
/// loop, and exposes view-models to SwiftUI. One instance per app lifetime.
@MainActor
public final class AppModel {
    public let dashboard = DashboardViewModel()
    public let charge = ChargeViewModel()
    public let compare = CompareViewModel()

    let panda = PandaClient()
    let tessie: TessieClient
    let fusion: DataFusionEngine
    let engine: RecommendationEngine
    let alertEngine = AlertEngine()
    let locationProvider = LocationProvider()
    let weather = WeatherClient()
    let corridor = CorridorModel.flatFallback()   // replaced by baked corridor pre-run

    var pack: PackProfile = .us2025PremiumRWD     // re-detected from CAN at startup
    var curve: ChargeCurveModel
    var learner = EfficiencyLearner()
    var preconditioner: PreconditionPlanner = {
        var p = PreconditionPlanner()
        p.targetWindowC = PackProfile.us2025PremiumRWD.idealSuperchargeCellTempC
        return p
    }()
    var planner: TripPlanner
    var sites = CorridorSeed.superchargers()

    private var latestState: VehicleState?
    private var latestSolution: TripPlanner.Solution?
    private var replanTask: Task<Void, Never>?

    public init(config: RunConfig) {
        tessie = TessieClient(vin: config.tessieVIN, token: config.tessieToken)
        curve = ChargeCurveModel(profile: pack)
        planner = TripPlanner(curve: curve, energy: learner.model, pack: pack)
        fusion = DataFusionEngine(initial: .zero)
        engine = RecommendationEngine(pack: pack, energy: learner.model)
        wire(config: config)
    }

    /// Persist credentials from Settings and hand them to the live client.
    /// A VIN change is a car swap: learned efficiency resets automatically.
    public func applySecrets(vin: String, token: String) {
        let vinChanged = vin != (SecretsStore.tessieVIN ?? "")
        SecretsStore.save(vin: vin, token: token)
        Task {
            await tessie.updateCredentials(vin: vin, token: token)
            if vinChanged { await resetLearnedEfficiency() }
            _ = try? await tessie.state(forceFresh: true)   // immediate validation poll
        }
    }

    /// Wipe everything learned about the current car (Wh/mi fit, charge-curve
    /// residuals, watchdog state) and reseed from the configured car's own
    /// drive history.
    public func resetLearnedEfficiency() async {
        learner = EfficiencyLearner()
        curve = ChargeCurveModel(profile: pack)
        planner = TripPlanner(curve: curve, energy: learner.model, pack: pack)
        await engine.resetLearning()
        didSeedEfficiency = false
        await seedEfficiencyFromHistory()
        lastPlanAt = .distantPast
        if let s = latestState { maybeReplan(s) }
    }

    func tessieStatus() async -> TessieClient.ConnectionStatus {
        await tessie.currentStatus()
    }

    // MARK: race mode — off = observe quietly, never coach

    var raceModeEnabled: Bool {
        UserDefaults.standard.object(forKey: "raceModeEnabled") as? Bool ?? true
    }

    public func setRaceMode(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "raceModeEnabled")
        Task { await engine.setEnabled(on) }
        if !on { dashboard.activeRecommendation = nil }
    }

    public struct CarSnapshot: Sendable {
        public var cloud: CloudVehicleState?
        public var pack: PackProfile
    }

    func carSnapshot() async -> CarSnapshot {
        CarSnapshot(cloud: await tessie.latestCloudState(), pack: pack)
    }

    public struct BatterySnapshot: Sendable {
        public var state: VehicleState?
        public var cloud: CloudVehicleState?
        public var pack: PackProfile
        public var canStreaming: Bool
    }

    func batterySnapshot() async -> BatterySnapshot {
        BatterySnapshot(state: latestState,
                        cloud: await tessie.latestCloudState(),
                        pack: pack,
                        canStreaming: await panda.currentStats().state == .streaming)
    }

    // MARK: chart data

    struct PlanProfile: Sendable {
        struct Point: Identifiable, Sendable { var id: Int; var mile: Double; var soc: Double }
        struct Stop: Identifiable, Sendable { var id: String; var mile: Double; var soc: Double; var name: String }
        var points: [Point]
        var stops: [Stop]
    }

    /// SOC-vs-distance sawtooth of the active plan, starting at the car's
    /// current SOC ("miles from here" on the x axis).
    func planProfile() -> PlanProfile? {
        guard let solution = latestSolution, let state = latestState,
              !solution.plan.legs.isEmpty else { return nil }
        var points = [PlanProfile.Point(id: 0, mile: 0, soc: state.socPercent.value)]
        var stops: [PlanProfile.Stop] = []
        var x = 0.0, idx = 1
        for (leg, stop) in zip(solution.plan.legs, solution.plan.stops) {
            x += leg.distanceMi
            points.append(.init(id: idx, mile: x, soc: stop.arrivalSOC)); idx += 1
            points.append(.init(id: idx, mile: x, soc: stop.departureSOC)); idx += 1
            let fullName = sites.first { $0.id == stop.siteID }?.name ?? stop.siteID
            stops.append(.init(id: stop.siteID, mile: x, soc: stop.arrivalSOC,
                               name: fullName.components(separatedBy: ",").first ?? fullName))
        }
        if solution.plan.legs.count > solution.plan.stops.count,
           let lastLeg = solution.plan.legs.last {
            let kWh = learner.model.predict(leg: lastLeg).kWh
            x += lastLeg.distanceMi
            points.append(.init(id: idx, mile: x,
                                soc: max(0, (points.last?.soc ?? 50) - kWh / pack.usableKWh * 100)))
        }
        return PlanProfile(points: points, stops: stops)
    }

    // MARK: road trips — any origin, any destination

    public private(set) var activeTrip: RouteCorridor?

    public func startTrip(to destination: CLLocationCoordinate2D, named name: String) async throws {
        guard let origin = await carCoordinate() else { throw TripError.noCarLocation }
        let route = try await Self.route(from: origin, to: destination)
        let chargers = try await SuperchargerDirectory.shared.sites()
        guard let corridor = RouteCorridor.build(
            routeCoordinates: route.coords,
            expectedTravelSeconds: route.seconds,
            destinationName: name,
            chargers: chargers)
        else { throw TripError.noRoute }

        activeTrip = corridor
        sites = corridor.sites
        dashboard.tripDestinationName = name
        dashboard.nextStopName = "Planning…"
        UserDefaults.standard.set(name, forKey: "trip.name")
        UserDefaults.standard.set(destination.latitude, forKey: "trip.lat")
        UserDefaults.standard.set(destination.longitude, forKey: "trip.lon")
        lastPlanSOC = -100; lastPlanAt = .distantPast
        runLog = RunLog(tripName: name, startedAt: .init(),
                        startSOC: latestState?.socPercent.value ?? 0,
                        startOdometerMi: latestState?.odometerMi.value)
        saveRunLog()
        if let s = latestState { maybeReplan(s) }
        Task { [weak self] in await self?.enrichTripEnvironment() }
    }

    /// Share the next planned Supercharger to the car's own navigation —
    /// the reliable trigger for on-route battery preconditioning.
    public func sendNextStopToCarNav() async -> String? {
        guard let stop = latestSolution?.plan.stops.first,
              let site = sites.first(where: { $0.id == stop.siteID }) else {
            return "No planned stop to send yet."
        }
        do {
            try await tessie.shareDestination(
                "\(site.coordinate.latitude),\(site.coordinate.longitude)")
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "Couldn't reach the car."
        }
    }

    public var plannedNextStopName: String? {
        latestSolution?.plan.stops.first.flatMap { stop in
            sites.first { $0.id == stop.siteID }?.name
        }
    }

    // MARK: map data

    struct TripMapData {
        struct StopPin: Identifiable {
            var id: String
            var name: String
            var coordinate: CLLocationCoordinate2D
            var arrivalSOC: Double?    // set = planned stop
            var amenity: String?
        }
        var route: [CLLocationCoordinate2D]
        var stops: [StopPin]
        var car: CLLocationCoordinate2D?
        var destinationName: String
    }

    func tripMapData() -> TripMapData? {
        guard let trip = activeTrip else { return nil }
        let route = stride(from: 0, to: trip.points.count, by: 4).map {
            CLLocationCoordinate2D(latitude: trip.points[$0].latitude,
                                   longitude: trip.points[$0].longitude)
        }
        let plannedByID = Dictionary(uniqueKeysWithValues:
            (latestSolution?.plan.stops ?? []).map { ($0.siteID, $0.arrivalSOC) })
        let pins = sites.map { s in
            TripMapData.StopPin(id: s.id, name: s.name, coordinate: s.coordinate,
                                arrivalSOC: plannedByID[s.id],
                                amenity: s.amenities.sorted().first)
        }
        return TripMapData(route: route, stops: pins,
                           car: latestState?.coordinate.value,
                           destinationName: trip.destinationName)
    }

    /// Background enrichment after a trip starts: dense terrain profile
    /// (~8 mi sampling) plus the first weather fetch. The corridor works
    /// immediately from site-elevation anchors; this sharpens it.
    private func enrichTripEnvironment() async {
        guard var trip = activeTrip else { return }
        let sampled = stride(from: 0, to: trip.points.count, by: 16).map { trip.points[$0] }
        if sampled.count >= 2,
           let elevations = try? await ElevationClient.elevations(
               latitudes: sampled.map(\.latitude), longitudes: sampled.map(\.longitude)),
           elevations.count == sampled.count {
            trip.applyElevation(zip(sampled, elevations).map { ($0.mile, $1) })
            guard activeTrip?.destinationName == trip.destinationName else { return }
            activeTrip = trip
        }
        await refreshTripWeather()
        lastPlanAt = .distantPast   // replan with the enriched physics
        if let s = latestState { maybeReplan(s) }
    }

    /// Forecast wind/temp/rain along the route at each point's predicted
    /// arrival hour, and hand it to the corridor's leg builder.
    private func refreshTripWeather() async {
        guard let snapshot = activeTrip else { return }
        let points = snapshot.weatherSamplePoints()
        guard !points.isEmpty else { return }
        let currentMile = latestState.map { snapshot.mile(of: $0.coordinate.value) } ?? 0
        let mph = max(30, snapshot.avgSpeedMps * 2.237)
        let hoursAhead = points.map { max(0, min(40, Int(($0.mile - currentMile) / mph))) }
        guard let rows = try? await weather.forecast(points: points, hoursAhead: hoursAhead)
        else { return }
        guard var trip = activeTrip, trip.destinationName == snapshot.destinationName
        else { return }
        trip.applyWeather(rows.map {
            .init(mile: $0.mile, headwindMps: $0.headwindMps, crosswindMps: $0.crosswindMps,
                  sigmaMps: $0.sigmaMps, ambientC: $0.ambientC,
                  precipMmPerHour: $0.precipMmPerHour)
        })
        activeTrip = trip
    }

    public func endTrip() {
        if var log = runLog {
            log.endedAt = .init()
            let ts = Int(log.startedAt.timeIntervalSince1970)
            try? JSONEncoder().encode(log).write(to:
                FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("runlog-\(ts).json"))
            lastCompletedLog = log
        }
        runLog = nil
        try? FileManager.default.removeItem(at: runLogURL)
        dashboard.paceText = nil; dashboard.etaText = nil
        activeTrip = nil
        sites = CorridorSeed.superchargers()
        dashboard.tripDestinationName = nil
        UserDefaults.standard.removeObject(forKey: "trip.name")
        UserDefaults.standard.removeObject(forKey: "trip.lat")
        UserDefaults.standard.removeObject(forKey: "trip.lon")
        lastPlanSOC = -100; lastPlanAt = .distantPast
        if let s = latestState { maybeReplan(s) }
    }

    /// Re-arm a saved trip once the car's position is known (app relaunch).
    private func restoreSavedTrip() async {
        guard let name = UserDefaults.standard.string(forKey: "trip.name") else { return }
        let dest = CLLocationCoordinate2D(
            latitude: UserDefaults.standard.double(forKey: "trip.lat"),
            longitude: UserDefaults.standard.double(forKey: "trip.lon"))
        for _ in 0..<12 {   // wait up to ~2 min for the first fix
            try? await Task.sleep(for: .seconds(10))
            guard activeTrip == nil else { return }
            if await carCoordinate() != nil {
                try? await startTrip(to: dest, named: name)
                return
            }
        }
    }

    private func carCoordinate() async -> CLLocationCoordinate2D? {
        if let s = latestState, s.coordinate.source != .deadReckoned {
            return s.coordinate.value
        }
        if let c = await tessie.latestCloudState() {
            return CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
        }
        return nil
    }

    private static func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D)
        async throws -> (coords: [CLLocationCoordinate2D], seconds: Double) {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = .automobile
        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else { throw TripError.noRoute }
        let buffer = route.polyline.points()
        let coords = (0..<route.polyline.pointCount).map { buffer[$0].coordinate }
        return (coords, route.expectedTravelTime)
    }

    // MARK: CAN bridge (S3XY Commander) — setting-driven, RX-only

    var canBridgeEnabled: Bool {
        UserDefaults.standard.bool(forKey: "canBridgeEnabled")
    }
    var canBridgeHost: String {
        UserDefaults.standard.string(forKey: "canBridgeHost") ?? "192.168.4.1"
    }

    public func setCANBridge(enabled: Bool, host: String) {
        let cleanHost = host.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(enabled, forKey: "canBridgeEnabled")
        UserDefaults.standard.set(cleanHost, forKey: "canBridgeHost")
        Task {
            await panda.stop()
            if enabled, !cleanHost.isEmpty {
                await panda.start(endpoint: .hostPort(host: NWEndpoint.Host(cleanHost),
                                                      port: 1338))
            }
        }
    }

    func canBridgeStats() async -> PandaClient.BridgeStats {
        await panda.currentStats()
    }

    private func wire(config: RunConfig) {
        Task {
            if canBridgeEnabled {
                await panda.start(endpoint: .hostPort(host: NWEndpoint.Host(canBridgeHost),
                                                      port: 1338))
            }
            await tessie.startStreaming()
            await fusion.attach(panda: panda, tessie: tessie,
                                gps: locationProvider.locations)
            await engine.attach(
                states: await fusion.states,
                corridor: { [weak self] in await self?.scorerCandidates() ?? [] },
                teslaNavSiteID: { [weak self] in await self?.teslaNavSiteID() })

            dashboard.bind(states: await fusion.states,
                           recommendations: await engine.recommendations)
            charge.bind(states: await fusion.states)
            await alertEngine.requestAuthorization()
            alertEngine.handle(await engine.recommendations)

            // Consume fused state on the model side for replans + calibration.
            for await state in await fusion.states {
                self.latestState = state
                self.maybeReplan(state)
                self.maybeCoach(state)
                self.recordRunLog(state)
                self.updateLiveEfficiency(state)
            }
        }
        // Hourly weather refresh; occupancy refresh at 90 s (docs §4.3/§4.5).
        Task { await refreshLoop() }
        Task { await restoreSavedTrip() }
        Task { await seedEfficiencyFromHistory() }
        Task { await engine.setEnabled(raceModeEnabled) }
        loadRunLog()
    }

    // MARK: efficiency seeding from cloud drive history

    private var didSeedEfficiency = false

    /// Calibrate the energy model from this car's real recent highway drives
    /// (Tessie /drives) so leg predictions are personal from mile zero.
    private func seedEfficiencyFromHistory() async {
        for _ in 0..<24 {
            if await tessie.hasCredentials { break }
            try? await Task.sleep(for: .seconds(5))
        }
        guard !didSeedEfficiency, await tessie.hasCredentials,
              let drives = try? await tessie.driveHistory(limit: 40) else { return }
        didSeedEfficiency = true
        let highway = drives
            .filter { $0.avgSpeedMph > 45 && $0.distanceMi > 10 }
            .sorted { $0.startedAt < $1.startedAt }
        for d in highway {
            learner.ingest(EfficiencyLearner.Segment(
                distanceMi: d.distanceMi, meanSpeedMps: d.avgSpeedMph * 0.44704,
                meanGradePercent: 0, headwindMps: 0, ambientC: d.outsideTempC,
                fsdActive: d.autopilotFraction > 0.5,
                actualKWh: d.energyKWh, startedAt: d.startedAt))
        }
    }

    // MARK: run log — automatic stop records + pace baseline

    private var runLog: RunLog?
    private(set) var lastCompletedLog: RunLog?
    private var wasDCCharging = false

    func currentRunLog() -> RunLog? { runLog ?? lastCompletedLog }

    private var runLogURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("runlog-current.json")
    }

    private func saveRunLog() {
        if let runLog { try? JSONEncoder().encode(runLog).write(to: runLogURL) }
    }

    private func loadRunLog() {
        runLog = (try? Data(contentsOf: runLogURL))
            .flatMap { try? JSONDecoder().decode(RunLog.self, from: $0) }
    }

    /// Live (SOC, kW) trace of the current DC session — feeds the Charge
    /// tab's session-vs-baseline overlay. Kept after unplug for review;
    /// cleared when the next session starts.
    struct SessionSample: Identifiable, Sendable {
        var id: Int; var soc: Double; var kW: Double
    }
    private(set) var liveSessionSamples: [SessionSample] = []

    private func recordRunLog(_ state: VehicleState) {
        let charging = state.isDCFastCharging.value
        defer { wasDCCharging = charging }
        if charging && !wasDCCharging { liveSessionSamples = [] }
        if charging { recordSessionSample(state) }
        guard runLog != nil else { return }
        if charging && !wasDCCharging {
            openStopRecord(state)
        } else if !charging && wasDCCharging {
            closeStopRecord(state)
        }
    }

    private func recordSessionSample(_ state: VehicleState) {
        let soc = state.socPercent.value
        let kW = state.chargePowerKW.value
        guard kW > 2 else { return }
        if let last = liveSessionSamples.last {
            guard soc >= last.soc, soc - last.soc > 0.15 || abs(kW - last.kW) > 4
            else { return }
        }
        liveSessionSamples.append(SessionSample(id: liveSessionSamples.count,
                                                soc: soc, kW: kW))
    }

    private func openStopRecord(_ state: VehicleState) {
        let coord = state.coordinate.value
        let here = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        let site = sites.min {
            here.distance(from: CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)) <
            here.distance(from: CLLocation(latitude: $1.coordinate.latitude, longitude: $1.coordinate.longitude))
        }
        let planned = latestSolution?.plan.stops.first { $0.siteID == site?.id }
        runLog?.stops.append(ChargeStopRecord(
            id: "\(site?.id ?? "site")-\(Int(Date().timeIntervalSince1970))",
            siteID: site?.id ?? "unknown",
            siteName: site?.name ?? "Supercharger",
            startedAt: .init(),
            arrivalSOC: state.socPercent.value,
            plannedArrivalSOC: planned?.arrivalSOC,
            plannedDepartureSOC: planned?.departureSOC,
            plannedChargeSeconds: planned?.chargeSeconds))
        saveRunLog()
    }

    private func closeStopRecord(_ state: VehicleState) {
        guard var log = runLog, var last = log.stops.last, last.endedAt == nil else { return }
        last.endedAt = .init()
        last.departureSOC = state.socPercent.value
        last.energyAddedKWh = max(0, (state.socPercent.value - last.arrivalSOC) / 100 * pack.usableKWh)
        log.stops[log.stops.count - 1] = last
        runLog = log
        saveRunLog()
    }

    // MARK: replanning

    private var lastPlanSOC = -100.0
    private var lastPlanAt = Date.distantPast

    private func maybeReplan(_ state: VehicleState) {
        let socDrift = abs(state.socPercent.value - lastPlanSOC)
        let age = Date().timeIntervalSince(lastPlanAt)
        // Off-plan refresh is a cheap passthrough of car data — keep the
        // ETA fresh; the full DP replan keeps the 5-minute cadence.
        let offPlan: Bool = if let trip = activeTrip {
            trip.distanceToRouteMi(state.coordinate.value) > Self.offRouteThresholdMi
        } else {
            nearestSiteDistanceMi(of: state.coordinate.value) > Self.offCorridorThresholdMi
        }
        let maxAge = offPlan ? 15.0 : 300.0
        guard socDrift > 1.5 || age > maxAge else { return }
        lastPlanSOC = state.socPercent.value
        lastPlanAt = .init()
        replanTask?.cancel()
        replanTask = Task.detached(priority: .utility) { [weak self] in
            await self?.replan(state)
        }
    }

    /// Corridor sites sit ≤ ~65 mi apart crow-flies; beyond this the car is
    /// genuinely off the run and the DP plan would be projection garbage.
    private static let offCorridorThresholdMi = 80.0
    /// A user trip has the actual polyline, so the deviation test is tight.
    private static let offRouteThresholdMi = 10.0

    private struct PlanContext {
        var destinationMile: Double
        var mile: Double
        var legBuilder: TripPlanner.LegBuilder
    }

    /// Shared by replan and the charge coach; nil means "off plan" and the
    /// caller should fall back to plain car data.
    private func planContext(for coord: CLLocationCoordinate2D,
                             ambientC: Double) async -> PlanContext? {
        if let trip = activeTrip {
            guard trip.distanceToRouteMi(coord) <= Self.offRouteThresholdMi else { return nil }
            return PlanContext(destinationMile: trip.destinationMile,
                               mile: trip.mile(of: coord),
                               legBuilder: trip.legBuilder(ambientTempC: ambientC))
        }
        guard nearestSiteDistanceMi(of: coord) <= Self.offCorridorThresholdMi else { return nil }
        return PlanContext(destinationMile: CorridorSeed.destinationMile,
                           mile: await routeMile(of: coord),
                           legBuilder: await corridor.legBuilderSnapshot())
    }

    private func freshPlanner() -> TripPlanner {
        var p = planner
        p.curve = curve
        p.energy = learner.model
        p.maxFanOut = activeTrip != nil ? 14 : 8
        return p
    }

    private func replan(_ state: VehicleState) async {
        let coord = state.coordinate.value
        guard let ctx = await planContext(for: coord, ambientC: state.ambientTempC.value) else {
            let cloud = await tessie.latestCloudState()
            await MainActor.run { self.dashboard.update(offCorridor: cloud) }
            return
        }
        let freshPlanner = freshPlanner()
        let problem = TripPlanner.Problem(
            sites: sites, destinationMile: ctx.destinationMile,
            currentMile: ctx.mile, currentSOC: state.socPercent.value,
            cellTempC: (state.cellTempMinC.value, state.cellTempMaxC.value),
            legBuilder: ctx.legBuilder)
        guard let solution = freshPlanner.solve(problem) else { return }
        let pinned: TripPlanner.Solution?
        if let navSite = await teslaNavSiteID() {
            // Same first stop → the plans genuinely agree; show ours as the
            // nav plan instead of pretending no comparison exists.
            pinned = navSite == solution.plan.stops.first?.siteID
                ? solution
                : freshPlanner.solvePinned(problem, firstStopID: navSite)
        } else {
            pinned = nil
        }
        if runLog != nil, runLog?.baselineTotalSeconds == nil {
            runLog?.baselineTotalSeconds = solution.plan.totalRemainingSeconds
            saveRunLog()
        }
        await MainActor.run {
            self.latestSolution = solution
            self.compare.siteAmenities = Dictionary(uniqueKeysWithValues:
                self.sites.map { ($0.id, $0.amenities.sorted().joined(separator: " · ")) })
                .filter { !$0.value.isEmpty }
            self.compare.update(optimized: solution.plan, teslaNav: pinned?.plan,
                                siteNames: Dictionary(uniqueKeysWithValues: self.sites.map { ($0.id, $0.name) }))
            self.dashboard.update(plan: solution.plan, siteNames: self.compare.siteNames)
            if let pinned {
                let deltaMin = Int(((pinned.plan.totalRemainingSeconds
                    - solution.plan.totalRemainingSeconds) / 60).rounded())
                self.dashboard.deltaVsTeslaText = deltaMin >= 0 ? "+\(deltaMin)" : "\(deltaMin)"
            } else {
                self.dashboard.deltaVsTeslaText = "—"
            }
            // Pace vs the first plan of the run.
            if let log = self.runLog, let baseline = log.baselineTotalSeconds {
                let projected = Date().timeIntervalSince(log.startedAt)
                    + solution.plan.totalRemainingSeconds
                let delta = projected - baseline
                self.dashboard.paceText = (delta >= 0 ? "+" : "-") + "\(abs(Int(delta / 60))) min"
                self.dashboard.paceIsAhead = delta <= 60
                self.dashboard.etaText = Date()
                    .addingTimeInterval(solution.plan.totalRemainingSeconds)
                    .formatted(date: .omitted, time: .shortened)
            }
        }
        await engine.updatePlans(optimized: solution.plan, teslaNav: pinned?.plan)
        if raceModeEnabled, !state.isDCFastCharging.value {
            await adviseDriving(state: state, solution: solution, currentMile: ctx.mile)
        }
    }

    // MARK: live advisors — the time-shaving nags

    /// Pace, plan-B, preconditioning, and charge-limit advice for the leg.
    private func adviseDriving(state: VehicleState, solution: TripPlanner.Solution,
                               currentMile: Double) async {
        guard let stop = solution.plan.stops.first,
              let leg = solution.plan.legs.first else { return }
        let stopSite = sites.first { $0.id == stop.siteID }
        let siteName = stopSite?.name ?? "the next stop"

        let legKWh = learner.model.predict(leg: leg).kWh
        let predicted = state.socPercent.value - legKWh / pack.usableKWh * 100
        let floor = pack.bufferFloorSOC

        if predicted < floor + 1.5 {
            // Safety: trending under the buffer floor is the ONLY reason to
            // slow for SOC — arriving below plan is otherwise a feature.
            await engine.submit(kind: .paceDown, message:
                "Slow down ~5 mph: trending to \(Int(predicted))% at \(siteName), against a \(Int(floor))% buffer floor.")
        } else {
            // Optimal cruise speed: sweep ±10 mph and price the extra Wh/mi
            // against minutes at the next plug. Faster driving that charges
            // back cheap (peak-zone arrival) often wins outright.
            let v0 = leg.avgSpeedMps
            var currentTotal = Double.infinity
            var best = (v: v0, total: Double.infinity)
            for step in -4...4 {
                let v = v0 + Double(step) * 1.118   // 2.5 mph increments
                guard v > 22 else { continue }
                var candidate = leg
                candidate.avgSpeedMps = v
                candidate.trafficDriveSeconds = leg.distanceMi * 1609.34 / v
                let kWh = learner.model.predict(leg: candidate).kWh
                let arrival = state.socPercent.value - kWh / pack.usableKWh * 100
                guard arrival >= floor else { continue }
                let chargeBack = curve.secondsToCharge(
                    from: arrival, to: stop.departureSOC,
                    cellTempStartC: (min: 35, max: 40),
                    siteVersion: stopSite?.version ?? .v3)
                let total = candidate.trafficDriveSeconds + chargeBack
                if step == 0 { currentTotal = total }
                if total < best.total { best = (v, total) }
            }
            if currentTotal.isFinite, best.total + 60 < currentTotal,
               abs(best.v - v0) >= 1.1 {
                let mph = Int((best.v * 2.23694).rounded())
                let saves = max(1, Int(((currentTotal - best.total) / 60).rounded()))
                let kind: Recommendation.Kind = best.v > v0 ? .paceUp : .paceDown
                let lead = best.v > v0 ? "Faster is free here" : "Backing off wins here"
                await engine.submit(kind: kind, message:
                    "\(lead): ~\(mph) mph is time-optimal this leg, saving about \(saves) min net of charging at \(siteName).")
            }
        }

        // Plan B: alert while passing the last fallback charger on a risky leg.
        if predicted < floor + 4, let stopSite {
            let fallbacks = sites.filter { site in
                site.routeMile > currentMile && site.routeMile < stopSite.routeMile - 1
                    && !solution.plan.stops.contains { $0.siteID == site.id }
            }
            if let last = fallbacks.max(by: { $0.routeMile < $1.routeMile }),
               last.routeMile - currentMile < 3 {
                await engine.submit(kind: .planB, message:
                    "Passing \(last.name): last charger before \(siteName) (\(Int(stopSite.routeMile - last.routeMile)) mi to go). Trending \(Int(predicted))% on arrival.",
                    critical: true)
            }
        }

        // Preconditioning: timed against arrival cell temperature. Only with
        // real temps — the placeholder fused state must never trigger this.
        let minutesToStop = leg.trafficDriveSeconds / 60
        if minutesToStop < 45, state.cellTempMaxC.source != .deadReckoned {
            let advice = preconditioner.advise(cellTempMaxC: state.cellTempMaxC.value,
                                               ambientC: state.ambientTempC.value,
                                               minutesToArrival: minutesToStop)
            if case .startNow = advice.action {
                let message = switch advice.mode {
                case .heat:
                    "Start preconditioning now to arrive at \(siteName) with cells at \(Int(advice.predictedArrivalTempWithPrecondition)) °C instead of \(Int(advice.predictedArrivalTempNoPrecondition)) °C."
                case .cool:
                    "Start precooling now: pack is trending to \(Int(advice.predictedArrivalTempNoPrecondition)) °C at \(siteName); cooling toward \(Int(advice.predictedArrivalTempWithPrecondition)) °C avoids the hot-side taper."
                }
                await engine.submit(kind: .preconditionNow, message: message)
            }
        }

        // Charge-limit guard: the car will stop the session under the plan.
        if let cloud = await tessie.latestCloudState(), let limit = cloud.chargeLimitSOC,
           stop.departureSOC > limit + 1 {
            await engine.submit(kind: .chargeLimit, message:
                "Raise the car's charge limit: it's set to \(Int(limit))% but the plan departs \(siteName) at \(Int(stop.departureSOC))%.")
        }
    }

    // MARK: live Wh/mi — rolling window over odometer + pack energy deltas

    private var efficiencySamples: [(odo: Double, kWh: Double)] = []

    private func updateLiveEfficiency(_ state: VehicleState) {
        guard !state.isDCFastCharging.value else {
            efficiencySamples.removeAll()          // a charge invalidates the window
            return
        }
        guard state.odometerMi.source != .deadReckoned,
              state.usableKWhRemaining.source != .deadReckoned else { return }
        let odo = state.odometerMi.value
        let kWh = state.usableKWhRemaining.value
        if let last = efficiencySamples.last {
            guard odo > last.odo + 0.3 else { return }
        }
        efficiencySamples.append((odo, kWh))
        while let first = efficiencySamples.first, odo - first.odo > 25 {
            efficiencySamples.removeFirst()
        }
        guard let first = efficiencySamples.first, odo - first.odo >= 8 else { return }
        let usedKWh = first.kWh - kWh
        guard usedKWh > 0.2 else { return }
        let whPerMi = usedKWh * 1000 / (odo - first.odo)
        dashboard.whPerMiText = "\(Int(whPerMi.rounded()))"
        if let leg = latestSolution?.plan.legs.first, leg.distanceMi > 1 {
            let planWhPerMi = learner.model.predict(leg: leg).kWh * 1000 / leg.distanceMi
            dashboard.efficiencyOnPlan = whPerMi <= planWhPerMi * 1.05
        }
    }

    private var lastCoachAt = Date.distantPast

    private func maybeCoach(_ state: VehicleState) {
        guard raceModeEnabled,
              state.isDCFastCharging.value,
              Date().timeIntervalSince(lastCoachAt) > 60 else { return }
        lastCoachAt = .init()
        Task { [weak self] in await self?.runChargeCoach(state) }
    }

    /// While plugged in: is the fastest move to leave, or to stretch?
    private func runChargeCoach(_ state: VehicleState) async {
        let coord = state.coordinate.value
        guard let ctx = await planContext(for: coord, ambientC: state.ambientTempC.value)
        else { return }
        let here = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        func meters(_ s: Supercharger) -> Double {
            here.distance(from: CLLocation(latitude: s.coordinate.latitude,
                                           longitude: s.coordinate.longitude))
        }
        guard let site = sites.min(by: { meters($0) < meters($1) }),
              meters(site) < 3200 else { return }   // must actually be at a site

        let problem = TripPlanner.Problem(
            sites: sites, destinationMile: ctx.destinationMile,
            currentMile: site.routeMile + 0.1,      // departing this stop
            currentSOC: state.socPercent.value,
            cellTempC: (state.cellTempMinC.value, state.cellTempMaxC.value),
            legBuilder: ctx.legBuilder)
        let planner = freshPlanner()
        let curveNow = curve
        let temp = (min: state.cellTempMinC.value, max: state.cellTempMaxC.value)
        let version = site.version
        let advice = await Task.detached(priority: .utility) {
            ChargeCoach.evaluate(planner: planner, problem: problem, curve: curveNow,
                                 siteVersion: version, cellTemp: temp)
        }.value
        guard let advice else { return }

        switch advice.call {
        case .leaveNow(let taper, let kW):
            let message = taper
                ? "Leave now: the curve has tapered to \(Int(kW)) kW. It's faster to run deeper into the pack and charge low again later."
                : "Leave now: more charge here costs more time than it saves."
            await engine.submit(kind: .departNow, message: message)
        case .chargeLonger(let extra, let saves, let skipsID):
            let message: String
            if let skipsID, let name = sites.first(where: { $0.id == skipsID })?.name {
                message = "Charge \(extra) more min and you can stretch past \(name), saving about \(saves) min overall."
            } else {
                message = "Stay \(extra) more min to save about \(saves) min overall."
            }
            await engine.submit(kind: .chargeLonger, message: message,
                                deltaSeconds: Double(saves * 60))
        }
    }

    /// Candidates near the next planned stop for the scorer/nav-challenger.
    private func scorerCandidates() async -> [SuperchargerScorer.Candidate] {
        guard let state = latestState, let solution = latestSolution else { return [] }
        let mile = await routeMile(of: state.coordinate.value)
        let legBuilder = await corridor.legBuilderSnapshot()
        let nextStopMile = sites.first { $0.id == solution.plan.stops.first?.siteID }?.routeMile
            ?? mile + 150
        return sites
            .filter { abs($0.routeMile - nextStopMile) < 60 && $0.routeMile > mile }
            .map { site in
                let after = sites.first { $0.routeMile > site.routeMile + 40 }
                return SuperchargerScorer.Candidate(
                    site: site,
                    legToSite: legBuilder(mile, site.routeMile),
                    legAfterSite: legBuilder(site.routeMile,
                                             after?.routeMile ?? CorridorSeed.destinationMile),
                    westbound: true,
                    downstreamSeconds: solution.downstreamSeconds[site.id] ?? 0)
            }
    }

    /// The car's nav counts as "planning a charging stop" ONLY when its route
    /// destination is literally a Supercharger (coordinate match). String
    /// matching against site names fabricates stops — "Samsung AUSTIN
    /// Semiconductor" once matched an Austin site — and the car's own
    /// intermediate charging stops are not visible over the API at all.
    private func teslaNavSiteID() async -> String? {
        guard let cloud = await tessie.latestCloudState(),
              let lat = cloud.activeRouteLatitude,
              let lon = cloud.activeRouteLongitude,
              (cloud.activeRouteMilesToArrival ?? 0) > 0.5 else { return nil }
        let dest = CLLocation(latitude: lat, longitude: lon)
        return sites.first { site in
            dest.distance(from: CLLocation(latitude: site.coordinate.latitude,
                                           longitude: site.coordinate.longitude)) < 1200
        }?.id
    }

    private func nearestSiteDistanceMi(of coord: CLLocationCoordinate2D) -> Double {
        let here = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        return sites.map {
            here.distance(from: CLLocation(latitude: $0.coordinate.latitude,
                                           longitude: $0.coordinate.longitude)) / 1609.34
        }.min() ?? .infinity
    }

    /// Project a coordinate onto the corridor. Seed implementation: nearest
    /// site anchor interpolation; the baked corridor replaces this with a
    /// proper polyline projection.
    private func routeMile(of coord: CLLocationCoordinate2D) async -> Double {
        let here = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        let nearest = sites.min {
            here.distance(from: CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)) <
            here.distance(from: CLLocation(latitude: $1.coordinate.latitude, longitude: $1.coordinate.longitude))
        }
        guard let nearest else { return 0 }
        let d = here.distance(from: CLLocation(latitude: nearest.coordinate.latitude,
                                               longitude: nearest.coordinate.longitude)) / 1609.34
        return max(0, nearest.routeMile - d)   // conservative: assume still approaching
    }

    // MARK: refresh loop

    private func refreshLoop() async {
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(90))
            tick += 1
            // Occupancy every tick (90 s)
            if let nearby = try? await tessie.nearbyChargingSites() {
                applyOccupancy(nearby)
            }
            // Weather hourly — trip corridor when active, seed otherwise.
            if tick % 40 == 0, activeTrip != nil {
                await refreshTripWeather()
            } else if tick % 40 == 0 {
                let points = sites.map {
                    WeatherClient.SamplePoint(mile: $0.routeMile, lat: $0.coordinate.latitude,
                                              lon: $0.coordinate.longitude, routeBearingDeg: 260)
                }
                if let rows = try? await weather.forecast(points: points,
                                                          hoursAhead: points.map { _ in 1 }) {
                    await corridor.applyWeather(rows.map {
                        (mile: $0.mile, headwind: $0.headwindMps, crosswind: $0.crosswindMps,
                         sigma: $0.sigmaMps, ambientC: $0.ambientC)
                    })
                }
            }
        }
    }

    private func applyOccupancy(_ nearby: [NearbyChargingSite]) {
        for n in nearby {
            let loc = CLLocation(latitude: n.latitude, longitude: n.longitude)
            if let idx = sites.firstIndex(where: {
                loc.distance(from: CLLocation(latitude: $0.coordinate.latitude,
                                              longitude: $0.coordinate.longitude)) < 800
            }) {
                sites[idx].occupancy = .live(available: n.availableStalls,
                                             total: n.totalStalls, asOf: .init())
                if n.siteClosed { sites[idx].healthScore = 0 }
            }
        }
    }
}

extension VehicleState {
    /// Neutral pre-telemetry snapshot used to seed the fusion engine.
    static var zero: VehicleState {
        let t = Date.distantPast
        func tag<V>(_ v: V) -> Tagged<V> { Tagged(v, source: .deadReckoned, timestamp: t) }
        return VehicleState(
            timestamp: t,
            coordinate: tag(.init(latitude: 40.746, longitude: -74.006)),  // Redball Garage
            speedMps: tag(0), headingDeg: tag(260), odometerMi: tag(50_000),
            socPercent: tag(80), usableKWhRemaining: tag(60),
            packVoltage: tag(346), packCurrentA: tag(0),
            cellTempMinC: tag(20), cellTempAvgC: tag(21), cellTempMaxC: tag(22),
            ambientTempC: tag(20), cabinTempC: tag(21), precondition: tag(.off),
            bmsMaxChargeKW: tag(250), bmsMaxDischargeKW: tag(300),
            isDCFastCharging: tag(false), chargePowerKW: tag(0),
            chargerMaxCurrentA: tag(0), fsdEngaged: tag(false))
    }
}
