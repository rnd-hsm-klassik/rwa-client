//
//  TelemetryKeys.swift
//  rwa client
//
//  CBOR key table for the BLE device telemetry feed.
//
//  CROSS-REPO CONTRACT (PROJECT-PLAN.md §5.3). Mirrored in rtk-rover as
//  src/telemetry/telemetry_keys.h. Never renumber or reuse a retired key
//  within a type; new fields get new keys, new event types get the next
//  free type value.
//

import Foundation

enum TelemetryKeys {

    /// Frame header: [u8 proto_version][u16 length LE][CBOR payload] (§5.2)
    static let protoVersion: UInt8 = 1

    // Common keys (every event)
    static let keyType: UInt64 = 0
    static let keySeq: UInt64 = 1
    static let keyTDevMs: UInt64 = 2

    // Event types (common key 0); JSON names per §4.3
    static let typeGnssFix: UInt64 = 1
    static let typeHeartbeat: UInt64 = 2
    static let typeNtripStatus: UInt64 = 3
    static let typeImuStatus: UInt64 = 4
    static let typeError: UInt64 = 5

    static let typeNames: [UInt64: String] = [
        typeGnssFix: "gnss_fix",
        typeHeartbeat: "heartbeat",
        typeNtripStatus: "ntrip_status",
        typeImuStatus: "imu_status",
        typeError: "error",
    ]

    /// Type-specific keys start at 10; numbers repeat across types (§5.3).
    static let fieldNames: [UInt64: [UInt64: String]] = [
        typeGnssFix: [
            10: "lat", 11: "lon", 12: "height_m", 13: "fix_type",
            14: "carr_soln", 15: "h_acc_mm", 16: "v_acc_mm", 17: "num_sv",
            18: "pdop", 19: "corr_age_ms",
        ],
        typeHeartbeat: [
            10: "uptime_ms", 11: "free_heap", 12: "wifi_rssi",
            13: "ntrip_connected", 14: "fw_version", 15: "dropped_frames",
        ],
        typeNtripStatus: [
            10: "state", 11: "reconnects", 12: "bytes_rx",
        ],
        typeImuStatus: [
            10: "calib_status", 11: "report_rate_hz", 12: "resets",
        ],
        typeError: [
            10: "severity", 11: "code", 12: "msg",
        ],
    ]

    /// ntrip_status.state travels as a uint enum on BLE; JSON wants the
    /// §4.3 strings.
    static let ntripStateNames: [UInt64: String] = [
        0: "disconnected", 1: "connected", 2: "reconnecting",
    ]

    // CTRL characteristic commands (§5.4): [u8 cmd][args...]
    static let ctrlSetVerbosity: UInt8 = 0x01  // arg: u8 = min error severity emitted
    static let ctrlStatusDump: UInt8 = 0x02    // no args
}
