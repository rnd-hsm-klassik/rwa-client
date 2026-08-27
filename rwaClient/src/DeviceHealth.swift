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
//    - HeadtrackerManager: BLE connect/disconnect + headset RSSI
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

    // Source attribution (AppTelemetrySampler): which component currently
    // feeds position / heading (TelemetrySource raw values: rtk_headtracker,
    // headtracker, phone, creator), nil = none.
    var positionSource: String?
    var headingSource: String?

    // Connected headset assembly: kind decided from GATT at connect
    // (AssemblyKind), id = the advertised BLE name. nil while disconnected.
    var assemblyKind: AssemblyKind?
    var assemblyId: String?

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

    /// Connected assembly identity, from the BLE central: kind from GATT
    /// discovery, id from the advertisement. Both nil on disconnect.
    func setAssembly(kind: AssemblyKind?, id: String?) {
        mutate {
            $0.assemblyKind = kind
            $0.assemblyId = id
        }
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

    /// Called at 1 Hz by AppTelemetrySampler; only mutates (and notifies)
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
            // Only firmware-created fixes own these fields; the app-created
            // samples (AppTelemetrySampler) describe a *different* position
            // and letting them write here made the fix display flap between
            // the RTK fix and internal GPS. That is guaranteed by the call
            // site (TelemetryService.recordDeviceEvent is the firmware path
            // only) — not by the event's fields, which all carry "source"
            // now. Which source drives the walk is the positionSource row's
            // job (setLiveSources), not this one's.
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

/// Head-tracking arrival statistics for the Diagnostics tab: rate,
/// inter-arrival jitter, staleness evidence (frames whose azimuth actually
/// changed vs frames received), plus drop count and device -> phone delay
/// jitter when the binary format's seq / t_dev_ms are available.
///
/// Fed by HeadtrackerManager on every heading frame (either wire format). Not
/// part of DeviceHealth: its mutate() posts a notification per write, which at
/// ~100 Hz would flood the main run loop. This class just accumulates under a
/// lock over 5s windows.
final class HeadingStats {

    static let shared = HeadingStats()

    enum WireFormat: String {
        case ascii = "ASCII (713D0002)"
        case binary = "binary (713D0005)"
    }

    struct Snapshot {
        var format: WireFormat?
        var rateHz: Double = 0
        var meanIntervalMs: Double = 0
        var maxIntervalMs: Double = 0
        var changedRatio: Double = 0     // azimuth-changed frames / frames, last window
        var frameCount = 0               // cumulative since connect
        var dropCount = 0                // cumulative seq gaps (binary only)
        var delayJitterMs: Double = 0    // spread of (arrival - t_dev_ms), last window
    }

    private let lock = NSLock()
    private var published = Snapshot()
    private var lastArrival: CFAbsoluteTime = 0
    private var windowStart: CFAbsoluteTime = 0
    private var windowFrames = 0
    private var windowChanged = 0
    private var windowIntervalSum = 0.0
    private var windowIntervalMax = 0.0
    private var windowSkewMin = Double.infinity   // arrival - t_dev, ms
    private var windowSkewMax = -Double.infinity
    private var lastSeq: UInt16?

    private init() {}

    /// New connection (or decoder switch): drop everything.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        published = Snapshot()
        lastArrival = 0; windowStart = 0
        resetWindowLocked()
        lastSeq = nil
    }

    func record(format: WireFormat, azimuthChanged: Bool, seq: UInt16?, tDevMs: UInt32?) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock(); defer { lock.unlock() }

        published.format = format
        published.frameCount += 1
        if let seq = seq {
            if let last = lastSeq {
                // Wrapping distance; a device reboot (seq restart) shows up as
                // a huge "gap" - ignore anything implausible for one interval.
                let gap = Int(seq &- last) - 1
                if gap > 0 && gap < 1000 { published.dropCount += gap }
            }
            lastSeq = seq
        }

        if windowStart == 0 { windowStart = now }
        windowFrames += 1
        if azimuthChanged { windowChanged += 1 }
        if lastArrival > 0 {
            let dt = (now - lastArrival) * 1000
            windowIntervalSum += dt
            if dt > windowIntervalMax { windowIntervalMax = dt }
        }
        lastArrival = now
        if let t = tDevMs {
            let skew = now * 1000 - Double(t)
            if skew < windowSkewMin { windowSkewMin = skew }
            if skew > windowSkewMax { windowSkewMax = skew }
        }

        // Tumbling 5 s window: publish and start over.
        let age = now - windowStart
        if age >= 5.0 {
            published.rateHz = Double(windowFrames) / age
            published.meanIntervalMs = windowFrames > 1
                ? windowIntervalSum / Double(windowFrames - 1) : 0
            published.maxIntervalMs = windowIntervalMax
            published.changedRatio = Double(windowChanged) / Double(windowFrames)
            published.delayJitterMs = windowSkewMax > windowSkewMin
                ? windowSkewMax - windowSkewMin : 0
            resetWindowLocked()
            windowStart = now
        }
    }

    /// For the Diagnostics refresh (0.5 s). Stats are those of the last
    /// completed 5 s window; the rate is zeroed once the stream stops.
    func snapshot() -> Snapshot {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock(); defer { lock.unlock() }
        var out = published
        if lastArrival == 0 || now - lastArrival > 2.0 {
            out.rateHz = 0
        }
        return out
    }

    private func resetWindowLocked() {
        windowFrames = 0; windowChanged = 0
        windowIntervalSum = 0; windowIntervalMax = 0
        windowSkewMin = .infinity; windowSkewMax = -.infinity
    }
}
