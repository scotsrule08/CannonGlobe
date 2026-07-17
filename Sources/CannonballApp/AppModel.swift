import Foundation
import CoreLocation
import CannonballCore

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
        Task { await tessie.updateCredentials(vin: vin, token: token) }
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
    }

    // MARK: replanning

    private var lastPlanSOC = -100.0
    private var lastPlanAt = Date.distantPast

    private func maybeReplan(_ state: VehicleState) {
        let socDrift = abs(state.socPercent.value - lastPlanSOC)
        let age = Date().timeIntervalSince(lastPlanAt)
        guard socDrift > 1.5 || age > 300 else { return }
        lastPlanSOC = state.socPercent.value
        lastPlanAt = .init()
        replanTask?.cancel()
        replanTask = Task.detached(priority: .utility) { [weak self] in
            await self?.replan(state)
        }
    }

    private func replan(_ state: VehicleState) async {
        let mile = await routeMile(of: state.coordinate.value)
        let legBuilder = await corridor.legBuilderSnapshot()
        var freshPlanner = planner
        freshPlanner.curve = curve
        freshPlanner.energy = learner.model
        let problem = TripPlanner.Problem(
            sites: sites, destinationMile: CorridorSeed.destinationMile,
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
