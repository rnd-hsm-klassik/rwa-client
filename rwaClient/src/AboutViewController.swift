//
//  AboutViewController.swift
//  rwa client
//
//  Diagnostics (About) tab. A read-only grouped table that surfaces the
//  live DeviceHealth snapshot: assembly connectivity, firmware heartbeat +
//  battery, IMU, GNSS fix quality, and identity/versions.
//

import UIKit

class AboutViewController: UITableViewController {

    private var refreshTimer: Timer?

    private struct Row {
        let label: String
        let value: String
    }
    private struct Section {
        let title: String
        let rows: [Row]
    }
    private var sections: [Section] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Diagnostics"
        rebuild()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        rebuild()
        refreshTimer = Timer.scheduledTimer(timeInterval: 0.5, target: self,
                                            selector: #selector(rebuild),
                                            userInfo: nil, repeats: true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Snapshot -> rows

    @objc private func rebuild() {
        let h = DeviceHealth.shared.snapshot
        var out: [Section] = []

        // Connectivity
        var conn: [Row] = []
        if useHeadTracker {
            let state: String
            if h.bleConnected {
                // The advertised name + kind of what is actually connected
                // (GATT-decided, DeviceHealth.setAssembly), so a mismatch
                // with the unit label is visible here too.
                let kind = h.assemblyKind.map {
                    $0 == .rtkHeadtracker ? "RTK headtracker" : "headtracker"
                }
                state = (h.assemblyId ?? "Connected") + (kind.map { " · \($0)" } ?? "")
            } else {
                state = "Disconnected"
            }
            conn.append(Row(label: "Headset assembly (BLE)",
                            value: state + Self.since(h.bleStateChangedAt)))
            conn.append(Row(label: "Signal (RSSI)", value: Self.dbm(h.rssi)))
        } else {
            conn.append(Row(label: "Heading", value: "Phone (device orientation)"))
        }
        conn.append(Row(label: "Last heartbeat", value: Self.age(h.lastHeartbeatAt)))
        out.append(Section(title: "Connectivity", rows: conn))

        // Assembly health (from the firmware heartbeat)
        out.append(Section(title: "Headset assembly", rows: [
            Row(label: "Battery", value: Self.battery(mv: h.batteryMv)),
            Row(label: "Firmware", value: h.fwVersion ?? "—"),
            Row(label: "Uptime", value: Self.uptime(h.uptimeMs))
        ]))

        // IMU (live orientation read straight from the head-tracker globals)
        var imu: [Row] = [
            Row(label: "Azimuth", value: "\(Int(hero.azimuth.rounded()))°"),
            Row(label: "Elevation", value: "\(Int(hero.elevation.rounded()))°"),
            Row(label: "Steps", value: "\(hero.stepCount)")
        ]
        if let c = h.imuCalibStatus { imu.append(Row(label: "Calibration", value: "\(c)")) }
        // Two different rates: the IMU samples on the device at ~75-100 Hz
        // (firmware imu_status), but the orientation reaches the app only once
        // per BLE connection event (HeadingStats, ~22-45 Hz on iOS depending on
        // the interval the phone granted).
        if let r = h.imuReportRateHz {
            imu.append(Row(label: "IMU sample rate (device)", value: String(format: "%.0f Hz", r)))
        }
        let hs = HeadingStats.shared.snapshot()
        if let format = hs.format {
            imu.append(Row(label: "Heading feed", value: format.rawValue))
            imu.append(Row(label: "Update rate (BLE)", value: String(format: "%.1f Hz", hs.updateRateHz)))
            imu.append(Row(label: "Interval mean ± sd / max",
                           value: String(format: "%.1f ± %.1f / %.0f ms",
                                         hs.meanIntervalMs, hs.sdIntervalMs, hs.maxIntervalMs)))
            imu.append(Row(label: "Frames per update", value: String(format: "%.2f", hs.framesPerUpdate)))
        }
        out.append(Section(title: "Motion data", rows: imu))

        // Correction link (caster -> app -> BLE -> assembly -> receiver,
        // ADR-001): the app's side of the BLE leg next to what the assembly
        // reports, so a gap between the two is visible.
        out.append(Section(title: "Correction link", rows: [
            Row(label: "RTCM to assembly (BLE)", value: Self.rtcmWritten(h)),
            Row(label: "RTCM to receiver", value: Self.bytesPerSecond(h.rtcmBytesPerInterval)),
            Row(label: "Correction age", value: Self.corrAge(h.corrAgeMs)),
            Row(label: "GGA from assembly", value: Self.age(h.lastAssemblyGgaAt))
        ]))

        // GNSS quality
        out.append(Section(title: "Global Navigation Satellite System quality", rows: [
            Row(label: "Position", value: Self.latlon(h.lat, h.lon)),
            Row(label: "Fix type", value: Self.fixType(h.fixType)),
            Row(label: "Carrier solution", value: Self.carrSoln(h.carrSoln)),
            Row(label: "Horizontal acc.", value: Self.mm(h.hAccMm)),
            Row(label: "Vertical acc.", value: Self.mm(h.vAccMm)),
            Row(label: "Satellites", value: h.numSv.map { "\($0)" } ?? "—"),
            Row(label: "PDOP", value: h.pdop.map { String(format: "%.1f", $0) } ?? "—"),
            Row(label: "Last fix", value: Self.age(h.lastFixAt))
        ]))

        // Identity & versions
        out.append(Section(title: "Identity & versions", rows: [
            Row(label: "Unit ID", value: TelemetryService.resolveDeviceId(
                configOverride: TelemetryService.shared?.config.unitIdOverride)),
            Row(label: "App", value: DeviceHealth.appVersion),
            Row(label: "Git commit", value: DeviceHealth.gitCommitHash)
        ]))

        sections = out
        tableView.reloadData()
    }

    // MARK: - UITableViewDataSource

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "cell")
        let row = sections[indexPath.section].rows[indexPath.row]
        cell.selectionStyle = .none
        cell.textLabel?.text = row.label
        cell.detailTextLabel?.text = row.value
        return cell
    }

    // MARK: - Formatting helpers

    private static func since(_ date: Date?) -> String {
        guard let date = date else { return "" }
        return " · \(age(date))"
    }

    private static func age(_ date: Date?) -> String {
        guard let date = date else { return "never" }
        let s = Int(Date().timeIntervalSince(date))
        if s < 1 { return "just now" }
        if s < 60 { return "\(s) s ago" }
        if s < 3600 { return "\(s / 60) min ago" }
        return "\(s / 3600) h ago"
    }

    private static func dbm(_ v: Int?) -> String { v.map { "\($0) dBm" } ?? "—" }
    private static func mm(_ v: Int?) -> String { v.map { "\($0) mm" } ?? "—" }

    /// Firmware heartbeat interval counters shown as a rate.
    private static func bytesPerSecond(_ perInterval: Int?) -> String {
        guard let v = perInterval else { return "—" }
        return String(format: "%.0f B/s", Double(v) / DeviceHealth.firmwareHeartbeatInterval)
    }

    private static func kilobytes(_ bytes: Int) -> String {
        return String(format: "%.1f KB", Double(bytes) / 1024)
    }

    /// The app-side RTCM counter: rate over the last heartbeat interval
    /// (comparable to "RTCM to receiver"), the total, and what the app's own
    /// queue dropped.
    private static func rtcmWritten(_ h: DeviceHealthSnapshot) -> String {
        guard h.rtcmDownlinkPresent else {
            if h.bleConnected && h.assemblyKind == .rtkHeadtracker {
                return "not offered (firmware ≤ 0.47)"
            }
            return "—"
        }
        var text = bytesPerSecond(h.rtcmWrittenPerInterval) + " · " + kilobytes(h.rtcmBytesWritten)
        if h.rtcmBytesDropped > 0 {
            text += " · dropped " + kilobytes(h.rtcmBytesDropped)
        }
        return text
    }

    /// Raw pack voltage: the firmware sends no percentage and a LiPo curve
    /// would only be guesswork here (single cell: ~4200 full, ~3300 empty).
    private static func battery(mv: Int?) -> String {
        guard let mv = mv else { return "—" }
        return String(format: "%.2f V", Double(mv) / 1000.0) + " (\(mv) mV)"
    }

    private static func uptime(_ ms: UInt32?) -> String {
        guard let ms = ms else { return "—" }
        let s = Int(ms) / 1000
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }

    private static func fixType(_ v: Int?) -> String {
        guard let v = v else { return "—" }
        switch v {
        case 0: return "No fix"
        case 1: return "Dead reckoning"
        case 2: return "2D"
        case 3: return "3D"
        case 4: return "GNSS + DR"
        default: return "\(v)"
        }
    }

    private static func carrSoln(_ v: Int?) -> String {
        guard let v = v else { return "—" }
        switch v {
        case 0: return "None"
        case 1: return "RTK float"
        case 2: return "RTK fixed"
        default: return "\(v)"
        }
    }

    private static func corrAge(_ ms: Int?) -> String {
        guard let ms = ms else { return "—" }
        if ms == 0xFFFFFFFF { return "never" }
        return "\(ms) ms"
    }

    private static func latlon(_ lat: Double?, _ lon: Double?) -> String {
        guard let lat = lat, let lon = lon else { return "—" }
        return String(format: "%.6f, %.6f", lat, lon)
    }

}
