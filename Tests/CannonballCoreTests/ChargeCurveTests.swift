import XCTest
@testable import CannonballCore

final class ChargeCurveTests: XCTestCase {
    let model = ChargeCurveModel(profile: .us2025PremiumRWD)

    func testPeakPowerAtLowSOC() {
        let kW = model.vehicleExpectedKW(soc: 10, cellTempMinC: 30, cellTempMaxC: 35)
        XCTAssertEqual(kW, 250, accuracy: 5, "warm pack at ~10% should hit the 250 kW peak")
        let at20 = model.vehicleExpectedKW(soc: 20, cellTempMinC: 30, cellTempMaxC: 35)
        XCTAssertLessThan(at20, 215, "NCA taper must already bite by 20% — the peak is brief")
    }

    func testTaperIsMonotonicAbovePlateau() {
        var last = Double.infinity
        for soc in stride(from: 30.0, through: 100, by: 5) {
            let kW = model.vehicleExpectedKW(soc: soc, cellTempMinC: 30, cellTempMaxC: 35)
            XCTAssertLessThanOrEqual(kW, last + 0.01, "taper must be monotone at SOC \(soc)")
            last = kW
        }
    }

    func testColdPackIsSeverelyLimited() {
        let cold = model.vehicleExpectedKW(soc: 15, cellTempMinC: 0, cellTempMaxC: 5)
        XCTAssertLessThan(cold, 95, "0 °C cells must cut power to roughly a third")
    }

    func testSiteVersionCapsPower() {
        let v2 = model.expectedKW(soc: 15, cellTempMinC: 30, cellTempMaxC: 35, siteVersion: .v2)
        XCTAssertEqual(v2, 150, accuracy: 1, "V2 cabinet caps well below the vehicle's 250 kW")
        let urban = model.expectedKW(soc: 15, cellTempMinC: 30, cellTempMaxC: 35, siteVersion: .v2urban)
        XCTAssertEqual(urban, 72, accuracy: 1)
    }

    func testBMSLimitBinds() {
        let kW = model.expectedKW(soc: 15, cellTempMinC: 30, cellTempMaxC: 35,
                                  siteVersion: .v3, bmsLimitKW: 90)
        XCTAssertEqual(kW, 90, accuracy: 0.1)
    }

    func testTenToSixtyIsFastWindow() {
        let warm = model.secondsToCharge(from: 10, to: 60, cellTempStartC: (40, 44), siteVersion: .v3)
        // 50% of 79 kWh (39.5 kWh) at ~155 kW mean ≈ 15 min + overhead.
        XCTAssertGreaterThan(warm / 60, 12)
        XCTAssertLessThan(warm / 60, 20)
        let toFull = model.secondsToCharge(from: 10, to: 100, cellTempStartC: (40, 44), siteVersion: .v3)
        XCTAssertGreaterThan(toFull, warm * 2.2,
            "top of the curve must be dramatically slower — this is why depart-SOC matters")
    }

    func testResidualLearningAdjustsExpectation() {
        var m = model
        let before = m.vehicleExpectedKW(soc: 55, cellTempMinC: 30, cellTempMaxC: 35)
        for _ in 0..<30 { m.observe(soc: 55, expected: before, actual: before * 0.9) }
        let after = m.vehicleExpectedKW(soc: 55, cellTempMinC: 30, cellTempMaxC: 35)
        XCTAssertLessThan(after, before * 0.97, "sustained shortfall must lower the expectation")
        XCTAssertGreaterThan(after, before * 0.85, "EWMA must not overreact")
    }

    func testChemistryDetection() {
        // 96s pack at mid SOC: LFP ≈ 3.3 V/cell → ~317 V; nickel ≈ 3.65 → ~350 V.
        XCTAssertEqual(PackProfile.detect(packVoltage: 317, socPercent: 50).chemistry, .lfp)
        XCTAssertEqual(PackProfile.detect(packVoltage: 352, socPercent: 50).chemistry, .nickel)
    }
}
