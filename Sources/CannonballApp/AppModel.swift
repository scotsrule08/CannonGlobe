import Foundation
import CoreLocation
import MapKit
import CannonballCore

public enum TripError: LocalizedError {
    case noCarLocation, noRoute

    public var errorDescription: String? {
        switch self {
        case .noCarLocation: "No car location yet — check the Tessie connection in Settings."
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
    var preconditioner = PreconditionPlanner()
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
    public func applySecrets(vin: String, token: String) {
        SecretsStore.save(vin: vin, token: token)
        Task {
            await tessie.updateCredentials(vin: vin, token: token)
            _ = try? await tessie.state(forceFresh: true)   // immediate validation poll
        }
    }

    func tessieStatus() async -> TessieClient.ConnectionStatus {
        await tessie.currentStatus()
    }

    public struct CarSnapshot: Sendable {
        public var cloud: CloudVehicleState?
        public var pack: PackProfile
    }

    func carSnapshot() async -> CarSnapshot {
        CarSnapshot(cloud: await tessie.latestCloudState(), pack: pack)
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
        if let s = latestState { maybeReplan(s) }
    }

    public func endTrip() {
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

    private func wire(config: RunConfig) {
        Task {
            await panda.start()
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
            }
        }
        // Hourly weather refresh; occupancy refresh at 90 s (docs §4.3/§4.5).
        Task { await refreshLoop() }
        Task { await restoreSavedTrip() }
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

    private func replan(_ state: VehicleState) async {
        let coord = state.coordinate.value
        let destinationMile: Double
        let mile: Double
        let legBuilder: TripPlanner.LegBuilder

        if let trip = activeTrip {
            guard trip.distanceToRouteMi(coord) <= Self.offRouteThresholdMi else {
                let cloud = await tessie.latestCloudState()
                await MainActor.run { self.dashboard.update(offCorridor: cloud) }
                return
            }
            destinationMile = trip.destinationMile
            mile = trip.mile(of: coord)
            legBuilder = trip.legBuilder(ambientTempC: state.ambientTempC.value)
        } else {
            guard nearestSiteDistanceMi(of: coord) <= Self.offCorridorThresholdMi else {
                let cloud = await tessie.latestCloudState()
                await MainActor.run { self.dashboard.update(offCorridor: cloud) }
                return
            }
            destinationMile = CorridorSeed.destinationMile
            mile = await routeMile(of: coord)
            legBuilder = await corridor.legBuilderSnapshot()
        }

        var freshPlanner = planner
        freshPlanner.curve = curve
        freshPlanner.energy = learner.model
        freshPlanner.maxFanOut = activeTrip != nil ? 14 : 8
        let problem = TripPlanner.Problem(
            sites: sites, destinationMile: destinationMile,
            currentMile: mile, currentSOC: state.socPercent.value,
            cellTempC: (state.cellTempMinC.value, state.cellTempMaxC.value),
            legBuilder: legBuilder)
        guard let solution = freshPlanner.solve(problem) else { return }
        let pinned: TripPlanner.Solution?
        if let navSite = await teslaNavSiteID(), navSite != solution.plan.stops.first?.siteID {
            pinned = freshPlanner.solvePinned(problem, firstStopID: navSite)
        } else {
            pinned = nil
        }
        await MainActor.run {
            self.latestSolution = solution
            self.compare.update(optimized: solution.plan, teslaNav: pinned?.plan,
                                siteNames: Dictionary(uniqueKeysWithValues: self.sites.map { ($0.id, $0.name) }))
            self.dashboard.update(plan: solution.plan, siteNames: self.compare.siteNames)
        }
        await engine.updatePlans(optimized: solution.plan, teslaNav: pinned?.plan)
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

    private func teslaNavSiteID() async -> String? {
        // Fleet active_route destination → nearest corridor site match.
        guard let dest = try? await tessie.state().activeRouteDestination else { return nil }
        return sites.first { dest.localizedCaseInsensitiveContains($0.name.split(separator: ",").first ?? "") }?.id
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
            // Weather hourly
            if tick % 40 == 0 {
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
