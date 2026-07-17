import XCTest
@testable import CannonballCore

final class SOCTargetTests: XCTestCase {
    func flatLeg(miles: Double, headwind: Double = 0) -> RouteLeg {
        let points = Int(miles * 1609.34 / 100) + 1
        return RouteLeg(
            fromSiteID: "a", toSiteID: "b", distanceMi: miles,
            elevation: ElevationProfile(stepMeters: 100,
                                        elevationsM: Array(repeating: 200, count: points)),
            wind: WindForecast(headwindMps: headwind, crosswindMps: 0),
            ambientTempC: 20,
            trafficDriveSeconds: miles / 70 * 3600,
            avgSpeedMps: 70 * 0.44704)
    }

    var calc: SOCTargetCalculator {
        SOCTargetCalculator(pack: .us2025PremiumRWD, energy: EnergyModel())
    }

    func testShortLegNeverAsksForEighty() {
        let t = calc.target(nextLeg: flatLeg(miles: 90))
        XCTAssertLessThan(t.departureSOC, 50,
            "a 90-mi flat leg must not demand a high charge — this is the whole point")
        XCTAssertGreaterThanOrEqual(t.predictedArrivalSOC, 5)
    }

    func testHeadwindRaisesTarget() {
        let calm = calc.target(nextLeg: flatLeg(miles: 120))
        let windy = calc.target(nextLeg: flatLeg(miles: 120, headwind: 9))  // ~20 mph headwind
        XCTAssertGreaterThan(windy.departureSOC, calm.departureSOC + 5,
            "20 mph headwind must add meaningful SOC")
    }

    func testDPFloorOnlyRaises() {
        let greedy = calc.target(nextLeg: flatLeg(miles: 90))
        let raised = calc.target(nextLeg: flatLeg(miles: 90), dpFloorSOC: greedy.departureSOC + 10)
        XCTAssertEqual(raised.departureSOC, greedy.departureSOC + 10, accuracy: 0.11)
        let ignored = calc.target(nextLeg: flatLeg(miles: 90), dpFloorSOC: greedy.departureSOC - 10)
        XCTAssertEqual(ignored.departureSOC, greedy.departureSOC, accuracy: 0.11)
    }

    func testBufferAdvisoryFiresWhenEroding() {
        let leg = flatLeg(miles: 150)
        let needed = calc.target(nextLeg: leg).departureSOC
        XCTAssertNil(calc.bufferAdvisory(currentSOC: needed + 5, remainingLeg: leg))
        XCTAssertNotNil(calc.bufferAdvisory(currentSOC: needed - 6, remainingLeg: leg))
    }

    func testEnergyModelSanity() {
        // 70 mph flat, 20 °C, no wind: a Highland RWD should run ~230–290 Wh/mi.
        let (kWh, _) = EnergyModel().predict(leg: flatLeg(miles: 100))
        let whPerMi = kWh * 1000 / 100
        XCTAssertGreaterThan(whPerMi, 200)
        XCTAssertLessThan(whPerMi, 310)
    }
}
