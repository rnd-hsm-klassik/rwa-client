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
