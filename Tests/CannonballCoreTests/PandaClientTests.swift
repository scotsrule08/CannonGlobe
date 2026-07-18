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

    func testDecodePackVoltAmp() throws {
        // 390.86 V → raw 39086 (0x98AE LE), −12.3 A → raw −123 as Int16.
        let volts = UInt16(39086)
        let amps = UInt16(bitPattern: Int16(-123))
        let frame = PandaClient.parseRecords(record(address: 0x132, payload: [
            UInt8(volts & 0xFF), UInt8(volts >> 8),
            UInt8(amps & 0xFF), UInt8(amps >> 8),
        ]))[0]
        let signals = CANDecoder().decode(frame)
        guard case let .packVoltAmp(v, a) = try XCTUnwrap(signals.first) else {
            return XCTFail("expected packVoltAmp")
        }
        XCTAssertEqual(v, 390.86, accuracy: 0.01)
        XCTAssertEqual(a, -12.3, accuracy: 0.01)
    }

    func testDecodeCellTemps() throws {
        // 0.25 °C/bit, −25 °C offset: 20 °C → 180, 30 °C → 220.
        let frame = PandaClient.parseRecords(record(address: 0x312, payload: [180, 220]))[0]
        guard case let .cellTemps(minC, maxC) = try XCTUnwrap(CANDecoder().decode(frame).first) else {
            return XCTFail("expected cellTemps")
        }
        XCTAssertEqual(minC, 20, accuracy: 0.01)
        XCTAssertEqual(maxC, 30, accuracy: 0.01)
    }

    func testDecodeEnergyStatus() throws {
        // 53.0 kWh remaining → 530, 75.0 full → 750, 0.1 kWh/bit.
        let frame = PandaClient.parseRecords(record(address: 0x352, payload: [
            0x12, 0x02,   // 530
            0xEE, 0x02,   // 750
        ]))[0]
        guard case let .energyStatus(remaining, full) = try XCTUnwrap(CANDecoder().decode(frame).first) else {
            return XCTFail("expected energyStatus")
        }
        XCTAssertEqual(remaining, 53.0, accuracy: 0.01)
        XCTAssertEqual(full, 75.0, accuracy: 0.01)
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
