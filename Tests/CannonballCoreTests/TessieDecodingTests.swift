import XCTest
@testable import CannonballCore

/// Decodes a REAL (sanitized) Tessie /state payload captured from a 2024
/// Model Y Performance — guards against the DTO drifting from what the API
/// actually serves.
final class TessieDecodingTests: XCTestCase {
    func loadFixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "Fixtures/tessie-state-modely", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    func testRealStatePayloadDecodes() throws {
        let dto = try JSONDecoder.tessie.decode(TessieStateDTO.self, from: loadFixture())
        let state = dto.toCloudState()

        XCTAssertEqual(state.displayName, "Tizzy")
        XCTAssertEqual(state.modelName, "Model Y")
        XCTAssertEqual(state.carType, "modely")
        XCTAssertEqual(state.trimBadging, "p74d")
        XCTAssertEqual(state.socPercent, 77, accuracy: 0.5)
        XCTAssertEqual(state.usableBatteryLevel ?? -1, 77, accuracy: 0.5)
        XCTAssertEqual(state.moduleTempMinC ?? -1, 30.5, accuracy: 0.1)
        XCTAssertEqual(state.moduleTempMaxC ?? -1, 31.0, accuracy: 0.1)
        XCTAssertEqual(state.packVoltage ?? -1, 390.86, accuracy: 0.1)
        XCTAssertEqual(state.energyRemainingKWh ?? -1, 53.08, accuracy: 0.1)
        XCTAssertEqual(state.chargeLimitSOC ?? -1, 100, accuracy: 0.5)
        XCTAssertEqual(state.chargingState, "Disconnected")
        XCTAssertEqual(state.odometerMi ?? -1, 49804, accuracy: 1)
        XCTAssertEqual(state.outsideTempC ?? -99, 31, accuracy: 0.5)
        XCTAssertNotNil(state.activeRouteDestination)
    }

    func testChemistryDetectionOnRealPack() throws {
        let dto = try JSONDecoder.tessie.decode(TessieStateDTO.self, from: loadFixture())
        let state = dto.toCloudState()
        // 390.86 V at 77% on a 96s pack ≈ 4.07 V/cell — unambiguously nickel.
        let pack = PackProfile.detect(packVoltage: state.packVoltage ?? 0,
                                      socPercent: state.socPercent)
        XCTAssertEqual(pack.chemistry, .nickel)
    }
}
