import XCTest
@testable import CannonballCore

final class TripPlannerTests: XCTestCase {
    let pack = PackProfile.us2025PremiumRWD

    var planner: TripPlanner {
        TripPlanner(curve: ChargeCurveModel(profile: pack),
                    energy: EnergyModel(), pack: pack)
    }

    /// Flat 70-mph corridor legs, calm air — the simulation baseline.
    static let flatBuilder: TripPlanner.LegBuilder = { from, to in
        let miles = to - from
        let points = max(2, Int(miles) + 1)
        return RouteLeg(
            fromSiteID: "", toSiteID: "", distanceMi: miles,
            elevation: ElevationProfile(stepMeters: 1609.34,
                                        elevationsM: Array(repeating: 300, count: points)),
            wind: WindForecast(headwindMps: 0, crosswindMps: 0),
            ambientTempC: 22,
            trafficDriveSeconds: miles / 70 * 3600,
            avgSpeedMps: 70 * 0.44704)
    }

    func makeProblem(currentSOC: Double = 90, currentMile: Double = 0) -> TripPlanner.Problem {
        TripPlanner.Problem(
            sites: CorridorSeed.superchargers(),
            destinationMile: CorridorSeed.destinationMile,
            currentMile: currentMile, currentSOC: currentSOC,
            cellTempC: (min: 22, max: 25),
            legBuilder: Self.flatBuilder)
    }

    func testFullCorridorIsFeasible() throws {
        let solution = try XCTUnwrap(planner.solve(makeProblem()))
        XCTAssertFalse(solution.plan.stops.isEmpty)
        // 2,790 mi at 70 mph ≈ 39.9 h drive; total with charging < 46 h.
        XCTAssertGreaterThan(solution.plan.totalRemainingSeconds, 39 * 3600)
        XCTAssertLessThan(solution.plan.totalRemainingSeconds, 46 * 3600)
        // NCA taper economics: roughly 9–14 stops, not 5 long ones.
        XCTAssertGreaterThanOrEqual(solution.plan.stops.count, 8)
        XCTAssertLessThanOrEqual(solution.plan.stops.count, 15)
    }

    func testNoStopChargesHigh() throws {
        let solution = try XCTUnwrap(planner.solve(makeProblem()))
        for stop in solution.plan.stops {
            XCTAssertLessThanOrEqual(stop.departureSOC, 86,
                "stop \(stop.siteID) charges to \(stop.departureSOC)% — the DP should avoid the taper")
            XCTAssertGreaterThanOrEqual(stop.arrivalSOC, pack.bufferFloorSOC - 0.01,
                "stop \(stop.siteID) violates the buffer floor")
        }
    }

    func testArrivalsAreLow() throws {
        let solution = try XCTUnwrap(planner.solve(makeProblem()))
        let meanArrival = solution.plan.stops.map(\.arrivalSOC).reduce(0, +)
            / Double(solution.plan.stops.count)
        XCTAssertLessThan(meanArrival, 20,
            "arrive-low strategy: mean arrival SOC should sit in the peak-power zone")
    }

    func testEndgameGoesDirect() throws {
        // 100 mi from the destination at 60% — no stop should be planned.
        let solution = try XCTUnwrap(planner.solve(
            makeProblem(currentSOC: 60, currentMile: CorridorSeed.destinationMile - 100)))
        XCTAssertTrue(solution.plan.stops.isEmpty, "endgame with ample SOC must go direct")
    }

    func testDownstreamSecondsMonotoneAlongRoute() throws {
        let solution = try XCTUnwrap(planner.solve(makeProblem()))
        let planned = solution.plan.stops.compactMap { stop in
            solution.downstreamSeconds[stop.siteID]
        }
        for (a, b) in zip(planned, planned.dropFirst()) {
            XCTAssertGreaterThan(a, b, "cost-to-go must shrink at each successive stop")
        }
    }

    func testPinnedPlanIsNeverFaster() throws {
        let p = makeProblem()
        let optimal = try XCTUnwrap(planner.solve(p))
        guard let firstStop = optimal.plan.stops.first?.siteID else { return XCTFail() }
        // Pin a deliberately different first stop and require it costs time.
        let otherSite = p.sites.first {
            $0.id != firstStop && $0.routeMile < 200 && $0.routeMile > 20
        }!
        if let pinned = planner.solvePinned(p, firstStopID: otherSite.id) {
            XCTAssertGreaterThanOrEqual(
                pinned.plan.totalRemainingSeconds + 1,
                optimal.plan.totalRemainingSeconds,
                "the optimizer must never lose to a pinned plan")
        }
    }
}
