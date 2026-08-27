//
//  Device.swift
//  BLEConnect
//
//  Created by Evan Stone on 8/15/16.
//  Copyright © 2016 Cloud City. All rights reserved.
//

import Foundation
import CoreBluetooth

struct Device {
    static let TransferService = "713D0000-503E-4C75-BA94-3148F18D941E"
    static let TransferCharacteristic = "713D0002-503E-4C75-BA94-3148F18D941E"

    static let TRACKERSERVICETX = "713D0002-503E-4C75-BA94-3148F18D941E"
    static let TRACKERSERVICERX = "713D0003-503E-4C75-BA94-3148F18D941E"
    static let TRACKERRAWDATA = "713D0004-503E-4C75-BA94-3148F18D941E"
    /// Binary heading frames (PROJECT-PLAN.md §5.5), rtk-rover ≥ 0.46.0.
    /// RWAHT assemblies don't have it and keep sending ASCII on ..0002.
    static let TRACKERBINARYHEADING = "713D0005-503E-4C75-BA94-3148F18D941E"

    // Telemetry GATT service (PROJECT-PLAN.md §5.1) — cross-repo contract
    static let TelemetryService = "713D0100-503E-4C75-BA94-3148F18D941E"
    static let TelemetryTxCharacteristic = "713D0101-503E-4C75-BA94-3148F18D941E"
    static let TelemetryCtrlCharacteristic = "713D0102-503E-4C75-BA94-3148F18D941E"
    
    // Tags
    static let EOM = "{{{EOM}}}"
    
    // We have a 20-byte limit for data transfer
    static let notifyMTU = 20
    static let centralRestoreIdentifier = "io.cloudcity.BLEConnect.CentralManager"
    static let peripheralRestoreIdentifier = "io.cloudcity.BLEConnect.PeripheralManager"

    /// Parse the tracker's raw position frame (TRACKERRAWDATA, 713D0004):
    /// "lat latHp lon lonHp" — UBX high-precision integers, 1e-7 degrees
    /// plus a 1e-9-degree high-res part. Returns degrees, or nil on any
    /// malformed frame (never trap on radio data).
    static func parseRawTrackerPosition(_ text: String) -> (lat: Double, lon: Double)? {
        let words = text.split(separator: " ")
        guard words.count == 4,
              let lat = Double(words[0]), let latHp = Double(words[1]),
              let lon = Double(words[2]), let lonHp = Double(words[3])
        else { return nil }
        return (lat: lat * 1e-7 + latHp * 1e-9,
                lon: lon * 1e-7 + lonHp * 1e-9)
    }

    /// One binary heading frame (TRACKERBINARYHEADING, 713D0005):
    /// 16 bytes little-endian, [seq u16][t_dev_ms u32][qi qj qk qw i16 Q14][linAccelZ i16 cm/s^2]
    struct HeadingFrame {
        let seq: UInt16       // device frame counter, restarts each boot; gaps = drops
        let tDevMs: UInt32    // device millis() at frame build
        let qi, qj, qk, qw: Float
        let linAccelZ: Float  // m/s²

        /// §5.5 canonical conversion — keep bit-identical with rwa-creator.
        /// The atan2 forms are scale-invariant, so the decoded (quantized)
        /// quaternion needs no normalization.
        var azimuthDeg: Float {
            var yaw = -atan2f(2 * (qi * qj + qk * qw),
                              qi * qi - qj * qj - qk * qk + qw * qw) * 180 / .pi
            if yaw < 0 { yaw += 360 }
            return yaw
        }
        var elevationDeg: Float {
            return -atan2f(2 * (qj * qk + qi * qw),
                           -qi * qi - qj * qj + qk * qk + qw * qw) * 180 / .pi
        }
    }

    /// Returns nil unless the frame is exactly 16 bytes (never trap on radio data).
    static func parseBinaryHeadingFrame(_ data: Data) -> HeadingFrame? {
        guard data.count == 16 else { return nil }
        let b = [UInt8](data)
        func u16(_ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
        func i16(_ o: Int) -> Int16 { Int16(bitPattern: u16(o)) }
        let q14: Float = 16384
        return HeadingFrame(
            seq: u16(0),
            tDevMs: UInt32(u16(2)) | UInt32(u16(4)) << 16,
            qi: Float(i16(6)) / q14,
            qj: Float(i16(8)) / q14,
            qk: Float(i16(10)) / q14,
            qw: Float(i16(12)) / q14,
            linAccelZ: Float(i16(14)) / 100
        )
    }
}
