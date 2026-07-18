import XCTest
@testable import CannonballCore

/// Wire-format + DBC decode verification for the S3XY Commander bridge —
/// everything provable without hardware, so the field probe only has to
/// confirm the endpoint and ID table.
final class PandaClientTests: XCTestCase {
    /// Build one 16-byte Panda record: [rir u32 LE | rdtr u32 LE | 8B data].
    func record(address: UInt32, bus: UInt8 = 0, payload: [UInt8]) -> Data {
        var d = Data()
        let rir = address << 21                       // 11-bit standard ID
        let rdtr = UInt32(payload.count) | (UInt32(bus) << 4)
        for shift in stride(from: 0, to: 32, by: 8) {
            d.append(UInt8((rir >> shift) & 0xFF))
        }
        for shift in stride(from: 0, to: 32, by: 8) {
            d.append(UInt8((rdtr >> shift) & 0xFF))
        }
        d.append(contentsOf: payload)
        d.append(contentsOf: repeatElement(0, count: 8 - payload.count))
        return d
    }

    func testParseRecordsFramingAndTrailingGarbage() {
        var datagram = record(address: 0x132, payload: [0x01, 0x02, 0x03, 0x04])
        datagram.append(record(address: 0x312, bus: 1, payload: [180, 220]))
        datagram.append(contentsOf: [0xDE, 0xAD, 0xBE])   // truncated tail
        let frames = PandaClient.parseRecords(datagram)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].address, 0x132)
        XCTAssertEqual(frames[0].data.count, 4)
        XCTAssertEqual(frames[1].address, 0x312)
        XCTAssertEqual(frames[1].bus, 1)
        XCTAssertEqual(Array(frames[1].data), [180, 220])
    }

    /// Pack an unsigned value of `length` bits at little-endian bit `start`
    /// into an 8-byte payload — the inverse of CANDecoder.signalLE.
    func pack(_ fields: [(start: Int, length: Int, value: UInt64)]) -> [UInt8] {
        var raw: UInt64 = 0
        for f in fields {
            let mask = (UInt64(1) << f.length) - 1
            raw |= (f.value & mask) << f.start
        }
        return (0..<8).map { UInt8((raw >> (8 * $0)) & 0xFF) }
    }

    func testDecodePackVoltAmp() throws {
        // BattVoltage132 @0 ×0.01 → 336.3 V (raw 33630). SmoothBattCurrent132
        // @16 signed ×-0.1: -19.7 A ⇒ raw +197.
        let payload = pack([(0, 16, 33630), (16, 16, 197)])
        let frame = PandaClient.parseRecords(record(address: 0x132, payload: payload))[0]
        guard case let .packVoltAmp(v, a) = try XCTUnwrap(CANDecoder().decode(frame).first) else {
            return XCTFail("expected packVoltAmp")
        }
        XCTAssertEqual(v, 336.3, accuracy: 0.05)
        XCTAssertEqual(a, -19.7, accuracy: 0.05)
    }

    func testDecodeCellTemps() throws {
        // 786: min @44 (9-bit), max @53 (9-bit), ×0.25 −25. 32 °C ⇒ 228, 38 °C ⇒ 252.
        let payload = pack([(44, 9, 228), (53, 9, 252)])
        let frame = PandaClient.parseRecords(record(address: 0x312, payload: payload))[0]
        guard case let .cellTemps(minC, maxC) = try XCTUnwrap(CANDecoder().decode(frame).first) else {
            return XCTFail("expected cellTemps")
        }
        XCTAssertEqual(minC, 32, accuracy: 0.01)
        XCTAssertEqual(maxC, 38, accuracy: 0.01)
    }

    func testDecodeEnergyStatus() throws {
        // 850: full @0 (11-bit) ×0.1 → 75.0 (raw 750); remaining @11 (11-bit) → 42.0 (raw 420).
        let payload = pack([(0, 11, 750), (11, 11, 420)])
        let frame = PandaClient.parseRecords(record(address: 0x352, payload: payload))[0]
        guard case let .energyStatus(remaining, full) = try XCTUnwrap(CANDecoder().decode(frame).first) else {
            return XCTFail("expected energyStatus")
        }
        XCTAssertEqual(remaining, 42.0, accuracy: 0.05)
        XCTAssertEqual(full, 75.0, accuracy: 0.05)
    }

    func testDecodeSOC() throws {
        // 292: SOCUI @10 (10-bit) ×0.1 → 67.0% (raw 670).
        let payload = pack([(0, 10, 632), (10, 10, 670), (20, 10, 676)])
        let frame = PandaClient.parseRecords(record(address: 0x292, payload: payload))[0]
        guard case let .soc(ui, mn, mx) = try XCTUnwrap(CANDecoder().decode(frame).first) else {
            return XCTFail("expected soc")
        }
        XCTAssertEqual(ui, 67.0, accuracy: 0.05)
        XCTAssertEqual(mn, 63.2, accuracy: 0.05)
        XCTAssertEqual(mx, 67.6, accuracy: 0.05)
    }

    func testDecodeBMSPower() throws {
        // 594: regen @0 ×0.01 → 60 kW (raw 6000); discharge @16 ×0.013 → 130 kW (raw 10000).
        let payload = pack([(0, 16, 6000), (16, 16, 10000)])
        let frame = PandaClient.parseRecords(record(address: 0x252, payload: payload))[0]
        guard case let .bmsPowerLimits(charge, discharge) = try XCTUnwrap(CANDecoder().decode(frame).first) else {
            return XCTFail("expected bmsPowerLimits")
        }
        XCTAssertEqual(charge, 60, accuracy: 0.1)
        XCTAssertEqual(discharge, 130, accuracy: 0.5)
    }

    func testSubscribePacketFormat() {
        // 0x0f header, then [0xff, idHi, idLo] per CAN ID (Commander protocol).
        let packet = PandaClient.subscribePacket(ids: [0x132, 0x2D2])
        XCTAssertEqual(Array(packet), [0x0f,
                                       0xff, 0x01, 0x32,
                                       0xff, 0x02, 0xD2])
    }

    func testAckFrameIsRecognized() {
        // Bus 15, frame 6 = the Commander ACK that triggers subscription.
        let rir = UInt32(6) << 21
        let rdtr = UInt32(0) | (UInt32(15) << 4)   // dlc 0, bus 15
        var d = Data()
        for shift in stride(from: 0, to: 32, by: 8) { d.append(UInt8((rir >> shift) & 0xFF)) }
        for shift in stride(from: 0, to: 32, by: 8) { d.append(UInt8((rdtr >> shift) & 0xFF)) }
        d.append(contentsOf: repeatElement(0, count: 8))
        let frame = PandaClient.parseRecords(d)[0]
        XCTAssertEqual(frame.bus, 15)
        XCTAssertEqual(frame.address, 6)
    }

    func testUnknownAddressDecodesNothing() {
        let frame = PandaClient.parseRecords(record(address: 0x7FF, payload: [1, 2, 3]))[0]
        XCTAssertTrue(CANDecoder().decode(frame).isEmpty)
    }
}
