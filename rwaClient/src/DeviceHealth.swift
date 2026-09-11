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
    var fwVersion: String?
    // RTCM bytes the firmware pushed into the receiver since its previous
    // heartbeat (key 21, rtk-rover ≥ 0.48.0; bytes/s = value / 15). With
    // corrAgeMs the assembly-side proof that corrections arrive. nil on
    // ≤ 0.47 firmware, which received its corrections over WiFi itself.
    var rtcmBytesPerInterval: Int?
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

    /// The firmware's heartbeat period (PROJECT-PLAN.md §4.3): the interval
    /// counters it carries (rtcm_bytes, loops_*) are "per this many seconds".
    static let firmwareHeartbeatInterval: TimeInterval = 15

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
                if let v = event["fw_version"] as? String { $0.fwVersion = v }
                if let v = DeviceHealth.int(event["rtcm_bytes"]) { $0.rtcmBytesPerInterval = v }
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

/// Head-tracking update statistics for the Diagnostics tab: the rate at
/// which the app's orientation is actually refreshed over BLE, with the mean,
/// jitter (standard deviation) and max of the update interval.
///
/// One update is one distinct arrival instant. Nothing leaves the assembly
/// between BLE connection events, so frames that ride the same event arrive
/// back to back (within ~1 ms) and refresh the same orientation: they are
/// folded into one update, not counted as separate ones. rtk-rover 0.46.0
/// sent 2-3 frames per event (which made the old per-notification count read
/// ~73 Hz on a ~33 Hz link); 0.46.2 paces to ~1.1. "Frames per update" says
/// how well that pacing holds (target 1.0). The fold threshold is far below
/// the shortest connection interval iOS grants (15 ms).
///
/// Fed by HeadtrackerManager on every heading frame (either wire format);
/// every frame is still applied to the hero and to step detection, only the
/// statistics coalesce. Not part of DeviceHealth: its mutate() posts a
/// notification per write, which at this rate would flood the main run loop.
/// This class just accumulates under a lock over tumbling 5 s windows.
final class HeadingStats {

    static let shared = HeadingStats()

    enum WireFormat: String {
        case ascii = "ASCII (713D0002)"
        case binary = "binary (713D0005)"
    }

    struct Snapshot {
        var format: WireFormat?
        var updateRateHz: Double = 0
        var meanIntervalMs: Double = 0
        var sdIntervalMs: Double = 0     // jitter: standard deviation of the update interval
        var maxIntervalMs: Double = 0
        var framesPerUpdate: Double = 0  // notifications folded into one update, last window
    }

    /// A frame this close to the previous one arrived in the same BLE
    /// connection event.
    static let sameEventThresholdMs = 5.0
    static let windowSeconds = 5.0

    private let lock = NSLock()
    private var published = Snapshot()
    private var lastUpdate: CFAbsoluteTime = 0   // arrival of the current update
    private var windowStart: CFAbsoluteTime = 0
    private var windowFrames = 0
    private var windowUpdates = 0
    private var intervalCount = 0
    private var intervalSum = 0.0
    private var intervalSumSq = 0.0
    private var intervalMax = 0.0

    private init() {}

    /// New connection (or decoder switch): drop everything.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        published = Snapshot()
        lastUpdate = 0; windowStart = 0
        resetWindowLocked()
    }

    /// `now` is injectable for tests only.
    func record(format: WireFormat, at now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        lock.lock(); defer { lock.unlock() }

        published.format = format

        let dt = (now - lastUpdate) * 1000
        if lastUpdate > 0 && dt < HeadingStats.sameEventThresholdMs {
            windowFrames += 1
            return   // same connection event as the previous frame: not a new update
        }

        // Tumbling window, closed by the first update that falls outside it,
        // so every update (and its folded frames) belongs to exactly one window.
        if windowStart > 0 && now - windowStart >= HeadingStats.windowSeconds {
            publishLocked(age: now - windowStart)
            resetWindowLocked()
            windowStart = 0
        }
        if windowStart == 0 { windowStart = now }

        windowFrames += 1
        windowUpdates += 1
        if lastUpdate > 0 {
            intervalCount += 1
            intervalSum += dt
            intervalSumSq += dt * dt
            if dt > intervalMax { intervalMax = dt }
        }
        lastUpdate = now
    }

    private func publishLocked(age: CFAbsoluteTime) {
        published.updateRateHz = Double(windowUpdates) / age
        if intervalCount > 0 {
            let mean = intervalSum / Double(intervalCount)
            let variance = max(0, intervalSumSq / Double(intervalCount) - mean * mean)
            published.meanIntervalMs = mean
            published.sdIntervalMs = variance.squareRoot()
        } else {
            published.meanIntervalMs = 0
            published.sdIntervalMs = 0
        }
        published.maxIntervalMs = intervalMax
        published.framesPerUpdate = windowUpdates > 0
            ? Double(windowFrames) / Double(windowUpdates) : 0
    }

    /// For the Diagnostics refresh (0.5 s). Stats are those of the last
    /// completed window; the rate is zeroed once the stream stops.
    func snapshot(at now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        var out = published
        if lastUpdate == 0 || now - lastUpdate > 2.0 {
            out.updateRateHz = 0
        }
        return out
    }

    private func resetWindowLocked() {
        windowFrames = 0; windowUpdates = 0
        intervalCount = 0; intervalSum = 0; intervalSumSq = 0; intervalMax = 0
    }
}
