import XCTest
import CoreLocation
@testable import CannonballCore

final class RouteCorridorTests: XCTestCase {
    /// Straight west-to-east route along latitude 35°, ~10° of longitude
    /// (≈ 566 mi), sampled every ~0.1°.
    func makeRoute() -> [CLLocationCoordinate2D] {
        stride(from: -100.0, through: -90.0, by: 0.1).map {
            CLLocationCoordinate2D(latitude: 35, longitude: $0)
        }
    }

    func makeChargers() -> [SuperchargerDirectory.Site] {
        // One on-route site each degree of longitude, plus one 30 mi off-route
        // and one weak site right next to a strong one (cluster test).
        var sites: [SuperchargerDirectory.Site] = []
        for (i, lon) in stride(from: -99.5, through: -90.5, by: 1.0).enumerated() {
            sites.append(.init(id: i, name: "OnRoute\(i)", latitude: 35.01, longitude: lon,
                               stallCount: 12, powerKilowatt: 250, elevationMeters: 300))
        }
        sites.append(.init(id: 100, name: "FarAway", latitude: 35.45, longitude: -95,
                           stallCount: 40, powerKilowatt: 250, elevationMeters: 300))
        sites.append(.init(id: 101, name: "WeakNeighbor", latitude: 35.02, longitude: -99.52,
                           stallCount: 4, powerKilowatt: 72, elevationMeters: 300))
        return sites
    }

    func build() -> RouteCorridor? {
        RouteCorridor.build(routeCoordinates: makeRoute(),
                            expectedTravelSeconds: 566.0 / 70 * 3600,
                            destinationName: "Test City",
                            chargers: makeChargers())
    }

    func testBuildProjectsOnRouteSitesOnly() throws {
        let corridor = try XCTUnwrap(build())
        XCTAssertEqual(corridor.destinationMile, 566, accuracy: 12)
        XCTAssertFalse(corridor.sites.contains { $0.name == "FarAway" },
                       "30 mi off-route must be excluded")
        XCTAssertFalse(corridor.sites.contains { $0.name == "WeakNeighbor" },
                       "clustering must keep the stronger site")
        XCTAssertEqual(corridor.sites.count, 10)
        // Sorted, increasing route miles roughly a degree (~56.6 mi) apart.
        let miles = corridor.sites.map(\.routeMile)
        XCTAssertEqual(miles, miles.sorted())
        XCTAssertEqual(miles[1] - miles[0], 56.6, accuracy: 6)
    }

    func testProjectionAndDeviation() throws {
        let corridor = try XCTUnwrap(build())
        let onRoute = CLLocationCoordinate2D(latitude: 35, longitude: -95)
        XCTAssertEqual(corridor.mile(of: onRoute), 283, accuracy: 12)
        XCTAssertLessThan(corridor.distanceToRouteMi(onRoute), 1)
        let offRoute = CLLocationCoordinate2D(latitude: 36, longitude: -95)
        XCTAssertEqual(corridor.distanceToRouteMi(offRoute), 69, accuracy: 3)
    }

    func testLegBuilderGeometry() throws {
        let corridor = try XCTUnwrap(build())
        let leg = corridor.legBuilder(ambientTempC: 22)(100, 200)
        XCTAssertEqual(leg.distanceMi, 100, accuracy: 0.1)
        // avg speed 70 mph → ~86 min of driving
        XCTAssertEqual(leg.trafficDriveSeconds, 100.0 / 70 * 3600, accuracy: 60)
        XCTAssertFalse(leg.elevation.elevationsM.isEmpty)
    }

    func testPlannerSolvesDynamicCorridor() throws {
        let corridor = try XCTUnwrap(build())
        let pack = PackProfile.us2025PremiumRWD
        var planner = TripPlanner(curve: ChargeCurveModel(profile: pack),
                                  energy: EnergyModel(), pack: pack)
        planner.maxFanOut = 14
        let problem = TripPlanner.Problem(
            sites: corridor.sites, destinationMile: corridor.destinationMile,
            currentMile: 0, currentSOC: 90,
            cellTempC: (min: 22, max: 25),
            legBuilder: corridor.legBuilder(ambientTempC: 22))
        let solution = try XCTUnwrap(planner.solve(problem))
        XCTAssertFalse(solution.plan.stops.isEmpty, "566 mi needs at least one stop")
        for stop in solution.plan.stops {
            XCTAssertGreaterThanOrEqual(stop.arrivalSOC, pack.bufferFloorSOC - 0.01)
        }
    }
}
