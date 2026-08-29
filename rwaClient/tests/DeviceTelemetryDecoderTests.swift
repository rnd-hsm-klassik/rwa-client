//
//  DeviceTelemetryDecoderTests.swift
//  rwaclientTests
//
//  Byte-exact tests for the device telemetry receive path: frame reassembly
//  (PROJECT-PLAN.md §5.2) and CBOR decoding with the §5.3 key table. The
//  expected byte sequences mirror the firmware's AUnit encoder tests
//  (rtk-rover src/telemetry/TestsTelemetry.h), so the two ends of the
//  contract are pinned against the same values.
//

import XCTest
import CoreBluetooth
@testable import rwa_client

final class DeviceTelemetryDecoderTests: XCTestCase {

    /// Wrap a CBOR payload in the §5.2 frame header [proto][u16 len LE].
    private func frame(_ payload: [UInt8], proto: UInt8 = 1) -> Data {
        return Data([proto, UInt8(payload.count & 0xFF), UInt8(payload.count >> 8)] + payload)
    }

    /// {0: 2 (heartbeat), 1: 65, 2: 1000, 12: -60, 13: true,
    ///  14: "0.44.0+abc", 16: 3900}
    private let heartbeatPayload: [UInt8] = [
        0xA7,                    // map, 7 pairs
        0x00, 0x02,              // 0: type = heartbeat
        0x01, 0x18, 0x41,        // 1: seq = 65
        0x02, 0x19, 0x03, 0xE8,  // 2: t_dev_ms = 1000
        0x0C, 0x38, 0x3B,        // 12: wifi_rssi = -60
        0x0D, 0xF5,              // 13: ntrip_connected = true
        0x0E, 0x6A] + Array("0.44.0+abc".utf8)  // 14: fw_version
        + [0x10, 0x19, 0x0F, 0x3C]  // 16: batt_mv = 3900

    func testHeartbeatDecodes() throws {
        var stream = TelemetryFrameStream()
        let payloads = stream.append(frame(heartbeatPayload))
        XCTAssertEqual(payloads.count, 1)

        let event = try XCTUnwrap(DeviceTelemetryDecoder.event(fromFramePayload: payloads[0]))
        XCTAssertEqual(event["type"] as? String, "heartbeat")
        // CBOR key 1 is the firmware's per-boot counter: it surfaces as
        // dev_seq, never as the dedup seq (that is the store row id, §4.2).
        XCTAssertEqual(event["dev_seq"] as? UInt64, 65)
        XCTAssertNil(event["seq"])
        XCTAssertEqual(event["source"] as? String, "rtk_headtracker")
        XCTAssertEqual(event["t_dev_ms"] as? UInt64, 1000)
        XCTAssertEqual(event["wifi_rssi"] as? Int64, -60)
        XCTAssertEqual(event["ntrip_connected"] as? Bool, true)
        XCTAssertEqual(event["fw_version"] as? String, "0.44.0+abc")
        XCTAssertEqual(event["batt_mv"] as? UInt64, 3900)
    }

    func testGnssFixFloatsDecode() throws {
        // {0: 1 (gnss_fix), 1: 1, 2: 5, 10: 1.5 (f64), 11: -0.5 (f64), 18: 1.5 (f32)}
        let payload: [UInt8] = [
            0xA6,
            0x00, 0x01,
            0x01, 0x01,
            0x02, 0x05,
            0x0A, 0xFB, 0x3F, 0xF8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // lat 1.5
            0x0B, 0xFB, 0xBF, 0xE0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,  // lon -0.5
            0x12, 0xFA, 0x3F, 0xC0, 0x00, 0x00,                          // pdop 1.5f
        ]
        let event = try XCTUnwrap(DeviceTelemetryDecoder.event(fromFramePayload: Data(payload)))
        XCTAssertEqual(event["type"] as? String, "gnss_fix")
        XCTAssertEqual(event["lat"] as? Double, 1.5)
        XCTAssertEqual(event["lon"] as? Double, -0.5)
        XCTAssertEqual(event["pdop"] as? Double, 1.5)
    }

    func testNtripStateMapsToString() throws {
        // {0: 3 (ntrip_status), 1: 2, 2: 9, 10: 1 (connected)}
        let payload: [UInt8] = [0xA4, 0x00, 0x03, 0x01, 0x02, 0x02, 0x09, 0x0A, 0x01]
        let event = try XCTUnwrap(DeviceTelemetryDecoder.event(fromFramePayload: Data(payload)))
        XCTAssertEqual(event["type"] as? String, "ntrip_status")
        XCTAssertEqual(event["state"] as? String, "connected")
    }

    func testFrameSpanningNotifications() {
        var stream = TelemetryFrameStream()
        let whole = frame(heartbeatPayload)
        let cut = whole.count / 2
        XCTAssertEqual(stream.append(whole.prefix(cut)).count, 0)
        let payloads = stream.append(whole.suffix(whole.count - cut))
        XCTAssertEqual(payloads.count, 1)
        XCTAssertNotNil(DeviceTelemetryDecoder.event(fromFramePayload: payloads[0]))
    }

    func testTwoFramesInOneNotification() {
        var stream = TelemetryFrameStream()
        let packed = frame(heartbeatPayload) + frame(heartbeatPayload)
        XCTAssertEqual(stream.append(packed).count, 2)
    }

    func testUnknownProtoDropsBuffer() {
        var stream = TelemetryFrameStream()
        XCTAssertEqual(stream.append(frame(heartbeatPayload, proto: 9)).count, 0)
        XCTAssertEqual(stream.desyncCount, 1)
        // After the desync flush, a fresh frame parses again.
        XCTAssertEqual(stream.append(frame(heartbeatPayload)).count, 1)
    }

    func testUnknownTypeIsDropped() {
        // {0: 99, 1: 1, 2: 1}
        let payload: [UInt8] = [0xA3, 0x00, 0x18, 0x63, 0x01, 0x01, 0x02, 0x01]
        XCTAssertNil(DeviceTelemetryDecoder.event(fromFramePayload: Data(payload)))
    }

    func testUnknownFieldKeyIsIgnored() throws {
        // heartbeat with an extra unknown key {99: 7} — additive rule §5.3
        let payload: [UInt8] = [
            0xA4,
            0x00, 0x02,
            0x01, 0x01,
            0x02, 0x01,
            0x18, 0x63, 0x07,  // 99: 7 (unknown)
        ]
        let event = try XCTUnwrap(DeviceTelemetryDecoder.event(fromFramePayload: Data(payload)))
        XCTAssertEqual(event["type"] as? String, "heartbeat")
        XCTAssertNil(event["99"])
    }

    func testTruncatedCborFailsCleanly() {
        // Map header claims 6 pairs but the payload ends early.
        let payload: [UInt8] = [0xA6, 0x00, 0x02, 0x01]
        XCTAssertNil(DeviceTelemetryDecoder.event(fromFramePayload: Data(payload)))
    }
}

/// The raw RTK position frames on TRACKERRAWDATA (713D0004):
/// "lat latHp lon lonHp", UBX 1e-7 degrees + 1e-9 high-res part.
final class TrackerPositionParserTests: XCTestCase {

    func testParsesHighPrecisionPosition() throws {
        let position = try XCTUnwrap(Device.parseRawTrackerPosition("473847362 45 85417210 -12"))
        XCTAssertEqual(position.lat, 47.3847362 + 45e-9, accuracy: 1e-12)
        XCTAssertEqual(position.lon, 8.5417210 - 12e-9, accuracy: 1e-12)
    }

    func testRejectsMalformedFrames() {
        XCTAssertNil(Device.parseRawTrackerPosition("l 47.3 8.5"))          // legacy format
        XCTAssertNil(Device.parseRawTrackerPosition("473847362 45 85417210"))  // 3 words
        XCTAssertNil(Device.parseRawTrackerPosition("abc def ghi jkl"))
        XCTAssertNil(Device.parseRawTrackerPosition(""))
    }
}

/// The binary heading frames on TRACKERBINARYHEADING (713D0005),
/// PROJECT-PLAN.md §5.5: 16 B little-endian, Q14 quaternion.
/// The angle checks pin the §5.5 canonical conversion that rwa-creator must mirror.
final class BinaryHeadingFrameTests: XCTestCase {

    /// [seq u16][t_dev_ms u32][qi qj qk qw i16 Q14][linAccelZ i16 cm/s²], LE.
    private func frame(seq: UInt16, tDevMs: UInt32,
                       qi: Int16, qj: Int16, qk: Int16, qw: Int16,
                       linAccelZ: Int16) -> Data {
        var b = [UInt8]()
        func le16(_ v: UInt16) { b.append(UInt8(v & 0xFF)); b.append(UInt8(v >> 8)) }
        le16(seq)
        le16(UInt16(tDevMs & 0xFFFF)); le16(UInt16(tDevMs >> 16))
        for q in [qi, qj, qk, qw, linAccelZ] { le16(UInt16(bitPattern: q)) }
        return Data(b)
    }

    func testDecodesFields() throws {
        let f = try XCTUnwrap(Device.parseBinaryHeadingFrame(
            frame(seq: 4711, tDevMs: 123_456_789,
                  qi: 16384, qj: -16384, qk: 0, qw: 8192, linAccelZ: -123)))
        XCTAssertEqual(f.seq, 4711)
        XCTAssertEqual(f.tDevMs, 123_456_789)
        XCTAssertEqual(f.qi, 1.0)
        XCTAssertEqual(f.qj, -1.0)
        XCTAssertEqual(f.qk, 0.0)
        XCTAssertEqual(f.qw, 0.5)
        XCTAssertEqual(f.linAccelZ, -1.23, accuracy: 1e-6)
    }

    func testRejectsWrongLength() {
        XCTAssertNil(Device.parseBinaryHeadingFrame(Data()))
        XCTAssertNil(Device.parseBinaryHeadingFrame(Data(repeating: 0, count: 15)))
        XCTAssertNil(Device.parseBinaryHeadingFrame(Data(repeating: 0, count: 17)))
    }

    func testIdentityQuaternionIsZeroAzimuthElevation() throws {
        let f = try XCTUnwrap(Device.parseBinaryHeadingFrame(
            frame(seq: 1, tDevMs: 0, qi: 0, qj: 0, qk: 0, qw: 16384, linAccelZ: 0)))
        XCTAssertEqual(f.azimuthDeg, 0.0, accuracy: 0.01)
        XCTAssertEqual(f.elevationDeg, 0.0, accuracy: 0.01)
    }

    /// +90° about z (q = (0,0,sin45,cos45)): §5.5 negates and wraps → 270°.
    func testYawQuarterTurn() throws {
        let s45 = Int16(11585) // round(sin(45°) · 16384)
        let f = try XCTUnwrap(Device.parseBinaryHeadingFrame(
            frame(seq: 1, tDevMs: 0, qi: 0, qj: 0, qk: s45, qw: s45, linAccelZ: 0)))
        XCTAssertEqual(f.azimuthDeg, 270.0, accuracy: 0.05)
        XCTAssertEqual(f.elevationDeg, 0.0, accuracy: 0.05)
    }

    /// +30° about x (q = (sin15,0,0,cos15)) → elevation −30°.
    func testElevationSign() throws {
        let f = try XCTUnwrap(Device.parseBinaryHeadingFrame(
            frame(seq: 1, tDevMs: 0, qi: 4241, qj: 0, qk: 0, qw: 15826, linAccelZ: 0)))
        XCTAssertEqual(f.elevationDeg, -30.0, accuracy: 0.05)
        XCTAssertEqual(f.azimuthDeg, 0.0, accuracy: 0.05)
    }
}

/// Assembly-kind detection from GATT: keyed on the RTK-only attributes
/// (telemetry service 713D0100, raw position 713D0004). Since RWAHT 0.3.0 both
/// kinds expose the binary heading characteristic 713D0005, so its presence
/// must not make an assembly "RTK".
final class AssemblyKindDetectionTests: XCTestCase {

    private let tracker = CBUUID(string: Device.TransferService)
    private let telemetry = CBUUID(string: Device.TelemetryService)
    private let ascii = CBUUID(string: Device.TRACKERSERVICETX)
    private let binaryHeading = CBUUID(string: Device.TRACKERBINARYHEADING)
    private let rawPosition = CBUUID(string: Device.TRACKERRAWDATA)

    /// RWAHT <= 0.2.x: tracker service with the ASCII characteristic only.
    func testLegacyRwahtIsPlainHeadtracker() {
        XCTAssertEqual(Device.assemblyKind(serviceUUIDs: [tracker],
                                           trackerCharacteristicUUIDs: [ascii]),
                       .headtracker)
    }

    /// RWAHT >= 0.3.0: adds 713D0005. still a plain headtracker.
    func testRwaht030StaysPlainHeadtrackerDespiteBinaryHeading() {
        XCTAssertEqual(Device.assemblyKind(serviceUUIDs: [tracker],
                                           trackerCharacteristicUUIDs: [ascii, binaryHeading]),
                       .headtracker)
    }

    /// rtk-rover >= 0.46.0: no ASCII characteristic, telemetry service and
    /// raw position present. Each RTK-only attribute is sufficient alone.
    func testRtkHeadtrackerDetectedByEitherRtkOnlyAttribute() {
        XCTAssertEqual(Device.assemblyKind(serviceUUIDs: [tracker, telemetry],
                                           trackerCharacteristicUUIDs: [binaryHeading, rawPosition]),
                       .rtkHeadtracker)
        // Kind is decided at service discovery, before characteristics arrive.
        XCTAssertEqual(Device.assemblyKind(serviceUUIDs: [tracker, telemetry],
                                           trackerCharacteristicUUIDs: []),
                       .rtkHeadtracker)
        // The 713D0004 fallback settles it even without the telemetry service.
        XCTAssertEqual(Device.assemblyKind(serviceUUIDs: [tracker],
                                           trackerCharacteristicUUIDs: [binaryHeading, rawPosition]),
                       .rtkHeadtracker)
    }
}
