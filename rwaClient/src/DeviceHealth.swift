//
//  DeviceHealth.swift
//  rwa client
//
//  Live, in-memory diagnostics snapshot for the Diagnostics (About) tab
//  and (later) a minimal Map-tab overlay. This is a read-side companion to
//  the telemetry gateway: the same device events that TelemetryService
//  persists to SQLite are also cached here as "latest value only", so the UI
//  can show current connectivity / heartbeat / GNSS quality without touching
//  the store or the audio/BLE hot paths.
//
//  Both the Diagnostics tab and the future Map badge
//  read DeviceHealth.shared.snapshot. Writers come from three places:
//    - SecondViewController: BLE connect/disconnect + headset RSSI
//    - TelemetryService.recordDeviceEvent: heartbeat / gnss_fix / imu_status
//    - TelemetryService uploader: pending backlog + upload result
//

import Foundation

/// Immutable copy of the current device health, handed to the UI on demand.
struct DeviceHealthSnapshot {
    // Connectivity (BLE headset link)
    var bleConnected = false
    var bleStateChangedAt: Date?
    var rssi: Int?                // headset BLE RSSI (dBm), nil until first read

    // Device heartbeat (PROJECT-PLAN.md §4.3 "heartbeat")
    var lastHeartbeatAt: Date?
    var uptimeMs: UInt32?
    var freeHeap: Int?
    var wifiRssi: Int?            // ESP32 -> hotspot link quality (dBm)
    var ntripConnected: Bool?
    var fwVersion: String?
    // LiPo pack voltage from the heartbeat (fw ≥ 0.44.0); nil until the first
    // heartbeat, and while the device reports 0 (= unknown). The firmware
    // ships no discharge curve, so this stays a raw voltage.
    var batteryMv: Int?

    // GNSS fix quality (PROJECT-PLAN.md §4.3 "gnss_fix")
    var lastFixAt: Date?
    var lat: Double?
    var lon: Double?
    var fixType: Int?
    var carrSoln: Int?           // 0 none, 1 RTK float, 2 RTK fixed
    var hAccMm: Int?
    var vAccMm: Int?
    var numSv: Int?
    var pdop: Double?
    var corrAgeMs: Int?

    // IMU status (PROJECT-PLAN.md §4.3 "imu_status"); live orientation is
    // read straight from the head-tracker globals by the UI.
    var imuCalibStatus: Int?
    var imuReportRateHz: Double?

    // Live telemetry source attribution (LiveTelemetrySource): which sensor
    // currently feeds position / heading ("rtk_tracker", "ios_gps",
    // "osc_sim", "headtracker_rtk", "headtracker", "ios_motion"), nil = none.
    var positionSource: String?
    var headingSource: String?

    // Telemetry gateway state
    var sessionId: String?
    var soundwalkId: String?
    var pendingUploads: Int?
    var uploadFailures: Int?
    var lastUploadStatus: Int?
}

final class DeviceHealth {

    static let shared = DeviceHealth()

    /// Posted after any mutation, in case a consumer prefers events to polling.
    static let didUpdate = Notification.Name("DeviceHealthDidUpdate")

    private let lock = NSLock()
    private var state = DeviceHealthSnapshot()

    private init() {}

    var snapshot: DeviceHealthSnapshot {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    // MARK: - Version helpers (shown in the Diagnostics "Versions" section)

    static let appVersion: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }()

    /// Injected at build time by the "Embed git hash" run-script phase.
    static let gitCommitHash: String = {
        (Bundle.main.infoDictionary?["GitCommitHash"] as? String).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "unknown"
    }()

    // MARK: - Writers

    func setBLEConnected(_ connected: Bool) {
        mutate {
            if $0.bleConnected != connected {
                $0.bleStateChangedAt = Date()
            }
            $0.bleConnected = connected
            if !connected { $0.rssi = nil }
        }
    }

    func setRSSI(_ rssi: Int) {
        mutate { $0.rssi = rssi }
    }

    func setTelemetrySession(sessionId: String, soundwalkId: String) {
        mutate {
            $0.sessionId = sessionId
            $0.soundwalkId = soundwalkId
        }
    }

    func setSoundwalkId(_ id: String) {
        mutate { $0.soundwalkId = id }
    }

    /// Called at 1 Hz by LiveTelemetrySource; only mutates (and notifies)
    /// when a source actually changed.
    func setLiveSources(position: String?, heading: String?) {
        lock.lock()
        let changed = state.positionSource != position || state.headingSource != heading
        if changed {
            state.positionSource = position
            state.headingSource = heading
        }
        lock.unlock()
        if changed {
            NotificationCenter.default.post(name: DeviceHealth.didUpdate, object: nil)
        }
    }

    func setUploadStats(pending: Int, failures: Int, lastStatus: Int?) {
        mutate {
            $0.pendingUploads = pending
            $0.uploadFailures = failures
            if let s = lastStatus { $0.lastUploadStatus = s }
        }
    }

    /// Tap point for device-origin telemetry. Mirrors the field mapping of
    /// PROJECT-PLAN.md §4.3; unknown types are ignored.
    func ingestDeviceEvent(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        switch type {
        case "heartbeat":
            mutate {
                $0.lastHeartbeatAt = Date()
                if let v = DeviceHealth.uint32(event["uptime_ms"]) { $0.uptimeMs = v }
                if let v = DeviceHealth.int(event["free_heap"]) { $0.freeHeap = v }
                if let v = DeviceHealth.int(event["wifi_rssi"]) { $0.wifiRssi = v }
                if let v = event["ntrip_connected"] as? Bool { $0.ntripConnected = v }
                if let v = event["fw_version"] as? String { $0.fwVersion = v }
                // 0 mV means the device could not read the pack: keep the
                // last known voltage rather than showing a flat battery.
                if let v = DeviceHealth.int(event["batt_mv"]), v > 0 { $0.batteryMv = v }
            }
        case "gnss_fix":
            // Only device-origin fixes own these fields. App-origin samples
            // carry a "source" tag (ios_gps / rtk_tracker / osc_sim,
            // LiveTelemetrySource) and describe a *different* position -
            // letting them write here made the fix display flap between the
            // RTK fix and internal GPS. Which source drives the walk is the
            // positionSource row's job (setLiveSources), not this one's.
            guard event["source"] == nil else { return }
            mutate {
                $0.lastFixAt = Date()
                if let v = DeviceHealth.double(event["lat"]) { $0.lat = v }
                if let v = DeviceHealth.double(event["lon"]) { $0.lon = v }
                if let v = DeviceHealth.int(event["fix_type"]) { $0.fixType = v }
                if let v = DeviceHealth.int(event["carr_soln"]) { $0.carrSoln = v }
                if let v = DeviceHealth.int(event["h_acc_mm"]) { $0.hAccMm = v }
                if let v = DeviceHealth.int(event["v_acc_mm"]) { $0.vAccMm = v }
                if let v = DeviceHealth.int(event["num_sv"]) { $0.numSv = v }
                if let v = DeviceHealth.double(event["pdop"]) { $0.pdop = v }
                if let v = DeviceHealth.int(event["corr_age_ms"]) { $0.corrAgeMs = v }
            }
        case "imu_status":
            mutate {
                if let v = DeviceHealth.int(event["calib_status"]) { $0.imuCalibStatus = v }
                if let v = DeviceHealth.double(event["report_rate_hz"]) { $0.imuReportRateHz = v }
            }
        default:
            break
        }
    }

    // MARK: - Private

    private func mutate(_ block: (inout DeviceHealthSnapshot) -> Void) {
        lock.lock()
        block(&state)
        lock.unlock()
        NotificationCenter.default.post(name: DeviceHealth.didUpdate, object: nil)
    }

    // Telemetry dicts carry Int / UInt32 / Double / NSNumber; normalize.
    private static func int(_ any: Any?) -> Int? {
        if let v = any as? Int { return v }
        return (any as? NSNumber)?.intValue
    }

    private static func uint32(_ any: Any?) -> UInt32? {
        if let v = any as? UInt32 { return v }
        if let v = any as? Int { return UInt32(truncatingIfNeeded: v) }
        return (any as? NSNumber)?.uint32Value
    }

    private static func double(_ any: Any?) -> Double? {
        if let v = any as? Double { return v }
        return (any as? NSNumber)?.doubleValue
    }
}
