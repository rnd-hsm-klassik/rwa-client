//
//  DeviceTelemetryDecoder.swift
//  rwa client
//
//  Device telemetry receive path (PROJECT-PLAN.md §5): reassembles the BLE
//  TX byte stream into frames, decodes the CBOR payloads with the §5.3 key
//  table, and hands finished events to TelemetryService.recordDeviceEvent.
//
//  The TX characteristic is a byte stream: one notification may carry
//  several concatenated frames and a frame may span notifications, so
//  reassembly goes strictly by the length prefix. There is no resync marker;
//  on a desync (unknown proto byte, implausible length) the buffer is
//  dropped and the stream recovers on the next (re)connect.
//

import Foundation
import os

// MARK: - Frame reassembly

/// Reassembles `[u8 proto][u16 len LE][payload]` frames from arbitrary
/// notification-sized chunks (§5.2). Value type, fully testable.
struct TelemetryFrameStream {

    /// Firmware caps frames at 192 B; anything larger means we lost sync.
    static let maxFrameLength = 512

    private var buffer = Data()
    private(set) var desyncCount = 0

    /// Feed one notification's bytes; returns every completed frame payload.
    mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var payloads: [Data] = []
        while buffer.count >= 3 {
            let base = buffer.startIndex
            let proto = buffer[base]
            let length = Int(buffer[base + 1]) | (Int(buffer[base + 2]) << 8)
            if proto != TelemetryKeys.protoVersion || length > TelemetryFrameStream.maxFrameLength {
                buffer.removeAll(keepingCapacity: true)
                desyncCount += 1
                break
            }
            let total = 3 + length
            guard buffer.count >= total else { break }
            payloads.append(buffer.subdata(in: (base + 3)..<(base + total)))
            buffer.removeFirst(total)
        }
        return payloads
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }
}

// MARK: - CBOR decoding

/// Minimal CBOR decoder (RFC 8949 subset) for §5.3 telemetry maps: one
/// definite-length map with unsigned-int keys; values may be uint, negint,
/// UTF-8 text, bool, float32 or float64. Anything else fails the frame
/// (dropped and counted by the receiver) rather than guessing.
enum TelemetryCbor {

    static func decodeMap(_ data: Data) -> [UInt64: Any]? {
        var reader = Reader(data)
        guard let head = reader.readHead(), head.major == 5 else { return nil }
        var map: [UInt64: Any] = [:]
        for _ in 0..<head.value {
            guard let keyHead = reader.readHead(), keyHead.major == 0,
                  let value = readValue(&reader)
            else { return nil }
            map[keyHead.value] = value
        }
        guard reader.isAtEnd else { return nil }
        return map
    }

    private static func readValue(_ reader: inout Reader) -> Any? {
        guard let head = reader.readHead() else { return nil }
        switch head.major {
        case 0:  // unsigned int
            return head.value
        case 1:  // negative int: -1 - n
            guard head.value <= UInt64(Int64.max) else { return nil }
            return -1 - Int64(head.value)
        case 3:  // text
            guard head.value <= UInt64(Int.max),
                  let bytes = reader.readBytes(Int(head.value))
            else { return nil }
            return String(bytes: bytes, encoding: .utf8)
        case 7:
            switch head.info {
            case 20: return false
            case 21: return true
            case 26: return Double(Float(bitPattern: UInt32(truncatingIfNeeded: head.value)))
            case 27: return Double(bitPattern: head.value)
            default: return nil
            }
        default:
            return nil  // byte strings, arrays, tags: not part of the contract
        }
    }

    private struct Reader {
        private let bytes: [UInt8]
        private var pos = 0

        init(_ data: Data) { bytes = [UInt8](data) }

        var isAtEnd: Bool { return pos == bytes.count }

        /// One CBOR head: major type, additional info, and the argument
        /// (immediate or from the 1/2/4/8-byte big-endian forms). For info
        /// 26/27 the argument carries the raw float bit pattern.
        mutating func readHead() -> (major: UInt8, info: UInt8, value: UInt64)? {
            guard pos < bytes.count else { return nil }
            let initial = bytes[pos]
            pos += 1
            let major = initial >> 5
            let info = initial & 0x1F
            switch info {
            case 0...23:
                return (major, info, UInt64(info))
            case 24, 25, 26, 27:
                let count = 1 << (Int(info) - 24)
                guard let extra = readBytes(count) else { return nil }
                var value: UInt64 = 0
                for byte in extra { value = value << 8 | UInt64(byte) }
                return (major, info, value)
            default:
                return nil  // indefinite lengths unsupported
            }
        }

        mutating func readBytes(_ count: Int) -> [UInt8]? {
            guard count >= 0, pos + count <= bytes.count else { return nil }
            defer { pos += count }
            return Array(bytes[pos..<(pos + count)])
        }
    }
}

// MARK: - Event mapping

/// One frame payload → one §4 event dictionary, or nil if undecodable.
/// The frame doesn't carry an identity and its counter is per boot.
/// CBOR key 1 becomes `dev_seq` (diagnostic).
/// Telemetry frames only ever come from the RTK headtracker's telemetry
/// characteristic, so `source` is stamped here.
enum DeviceTelemetryDecoder {

    static func event(fromFramePayload payload: Data) -> [String: Any]? {
        guard let map = TelemetryCbor.decodeMap(payload),
              let typeRaw = map[TelemetryKeys.keyType] as? UInt64,
              let typeName = TelemetryKeys.typeNames[typeRaw],
              let fieldNames = TelemetryKeys.fieldNames[typeRaw]
        else { return nil }  // unknown type ids are dropped (§5.3)

        var event: [String: Any] = [
            "type": typeName,
            TelemetrySource.fieldName: TelemetrySource.rtkHeadtracker.rawValue
        ]
        if let seq = map[TelemetryKeys.keySeq] { event["dev_seq"] = seq }
        if let tDevMs = map[TelemetryKeys.keyTDevMs] { event["t_dev_ms"] = tDevMs }
        for (key, value) in map where key >= 10 {
            if let name = fieldNames[key] {
                event[name] = value
            }
            // unknown keys within a known type: ignored (§5.3 additive rule)
        }

        if typeRaw == TelemetryKeys.typeNtripStatus, let state = event["state"] as? UInt64 {
            event["state"] = TelemetryKeys.ntripStateNames[state] ?? "unknown"
        }
        return event
    }
}

// MARK: - Receiver

/// Singleton fed by the BLE delegate (HeadtrackerManager). Cheap on the
/// delegate queue: reassemble, decode, hand off — TelemetryService moves
/// every event to its own serial queue immediately.
final class DeviceTelemetryReceiver {

    static let shared = DeviceTelemetryReceiver()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "RWA Player",
                                category: "Device Telemetry")
    private var stream = TelemetryFrameStream()
    private var undecodableFrames = 0
    private var lastFwVersion: String?

    func ingest(_ data: Data) {
        for payload in stream.append(data) {
            guard let event = DeviceTelemetryDecoder.event(fromFramePayload: payload) else {
                undecodableFrames += 1
                logger.error("device telemetry: dropped undecodable frame (\(self.undecodableFrames) total)")
                continue
            }
            if event["type"] as? String == "heartbeat",
               let fwVersion = event["fw_version"] as? String,
               fwVersion != lastFwVersion {
                lastFwVersion = fwVersion
                TelemetryService.shared?.updateFwVersion(fwVersion)
            }
            TelemetryService.shared?.recordDeviceEvent(event)
        }
    }

    /// Call on BLE disconnect: a partially received frame must not be glued
    /// to bytes from the next connection.
    func connectionReset() {
        stream.reset()
    }
}
