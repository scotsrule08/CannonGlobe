import XCTest
import CoreLocation
@testable import CannonballCore

final class ChargeCoachTests: XCTestCase {
    let pack = PackProfile.us2025PremiumRWD

    var planner: TripPlanner {
        TripPlanner(curve: ChargeCurveModel(profile: pack),
                    energy: EnergyModel(), pack: pack)
    }

    func problem(currentSOC: Double, atMile: Double) -> TripPlanner.Problem {
        TripPlanner.Problem(
            sites: CorridorSeed.superchargers(),
            destinationMile: CorridorSeed.destinationMile,
            currentMile: atMile, currentSOC: currentSOC,
            cellTempC: (min: 35, max: 40),
            legBuilder: TripPlannerTests.flatBuilder)
    }

    func testEarlySessionSaysStay() {
        // 15% into a session mid-corridor: leaving now would strand or force
        // an immediate extra stop — the coach must not say "leave".
        let advice = ChargeCoach.evaluate(
            planner: planner, problem: problem(currentSOC: 15, atMile: 1080),
            curve: ChargeCurveModel(profile: pack),
            siteVersion: .v3, cellTemp: (min: 35, max: 40))
        if case .leaveNow = advice?.call {
            XCTFail("coach told us to leave at 15% mid-corridor")
        }
    }

    func testDeepTaperSaysLeave() throws {
        // 85% mid-corridor: every extra minute is deep-taper time the DP
        // would rather spend at the next stop's peak-power zone.
        let advice = try XCTUnwrap(ChargeCoach.evaluate(
            planner: planner, problem: problem(currentSOC: 85, atMile: 1080),
            curve: ChargeCurveModel(profile: pack),
            siteVersion: .v3, cellTemp: (min: 40, max: 44)))
        guard case .leaveNow(let taper, let kW) = advice.call else {
            return XCTFail("expected leaveNow at 85%, got \(advice.call)")
        }
        XCTAssertTrue(taper, "85% is deep in the taper")
        XCTAssertLessThan(kW, 80, "taper power at 85% must be far off peak")
    }

    func testSocAfterChargingIntegratesCurve() {
        let curve = ChargeCurveModel(profile: pack)
        let after10 = ChargeCoach.socAfterCharging(
            minutes: 10, from: 15, curve: curve,
            cellTemp: (min: 40, max: 44), siteVersion: .v3)
        // ~10 min near peak power (≈220 kW avg) ≈ 36 kWh ≈ +48% — generous
        // bounds since warming shifts the operating point.
        XCTAssertGreaterThan(after10, 35)
        XCTAssertLessThan(after10, 70)
        let after0 = ChargeCoach.socAfterCharging(
            minutes: 0, from: 15, curve: curve,
            cellTemp: (min: 40, max: 44), siteVersion: .v3)
        XCTAssertEqual(after0, 15, accuracy: 0.01)
    }
}
