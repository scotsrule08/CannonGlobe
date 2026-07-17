import XCTest
@testable import CannonballCore

final class PreconditionPlannerTests: XCTestCase {
    var planner: PreconditionPlanner {
        var p = PreconditionPlanner()
        p.targetWindowC = PackProfile.us2025PremiumRWD.idealSuperchargeCellTempC   // 40...48
        return p
    }

    func testMildWeatherFarOutSaysWait() {
        // 25 °C cells, 22 °C air, 3 h out: deficit ≈ 15 °C ≈ 23 min of
        // heating — nowhere near time to start.
        let advice = planner.advise(cellTempMaxC: 25, ambientC: 22, minutesToArrival: 180)
        guard case .startInMinutes(let m) = advice.action else {
            return XCTFail("expected startInMinutes, got \(advice.action)")
        }
        XCTAssertGreaterThan(m, 120, "3 h out must not precondition yet")
        XCTAssertEqual(advice.mode, .heat)
    }

    func testColdAirNeedsMoreLeadTime() {
        func startIn(ambient: Double) -> Int {
            guard case .startInMinutes(let m) = planner.advise(
                cellTempMaxC: 20, ambientC: ambient, minutesToArrival: 180).action
            else { XCTFail(); return 0 }
            return m
        }
        XCTAssertLessThan(startIn(ambient: -5), startIn(ambient: 20),
                          "cold air derates the heater, so it must start earlier")
    }

    func testExtremeHeatAdvisesPrecooling() {
        // 44 °C cells drifting toward ambient+15 ≈ 60 °C over a long leg:
        // arriving that hot craters charge power — must call for cooling.
        let advice = planner.advise(cellTempMaxC: 44, ambientC: 45, minutesToArrival: 120)
        XCTAssertEqual(advice.mode, .cool)
        switch advice.action {
        case .startNow, .startInMinutes: break
        default: XCTFail("expected active precooling, got \(advice.action)")
        }
        XCTAssertGreaterThan(advice.predictedArrivalTempNoPrecondition, 48)
        XCTAssertLessThanOrEqual(advice.predictedArrivalTempWithPrecondition, 48)
    }

    func testDesertAirDeratesCooling() {
        let p = planner
        XCTAssertLessThan(p.effectiveCoolRateCPerMin(ambientC: 47),
                          p.effectiveCoolRateCPerMin(ambientC: 25))
        XCTAssertGreaterThanOrEqual(p.effectiveCoolRateCPerMin(ambientC: 60),
                                    p.precoolRateCPerMin * 0.5, "floor holds")
    }

    func testInWindowArrivalSkips() {
        // Cells already at the window's edge, warm day, short hop:
        // self-heats into the window — no action needed.
        let advice = planner.advise(cellTempMaxC: 40, ambientC: 32, minutesToArrival: 30)
        guard case .skip = advice.action else {
            return XCTFail("expected skip, got \(advice.action)")
        }
    }
}
