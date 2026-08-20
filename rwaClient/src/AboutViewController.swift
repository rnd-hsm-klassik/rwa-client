//
//  AboutViewController.swift
//  rwa client
//
//  Diagnostics (About) tab. A read-only grouped table that surfaces the
//  live DeviceHealth snapshot: connectivity, headset heartbeat + battery,
//  head-tracker IMU, GNSS fix quality, telemetry backlog (to be revised), and app/git
//  versions.
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
            let state = h.bleConnected ? "Connected" : "Disconnected"
            conn.append(Row(label: "Head tracker (BLE)",
                            value: state + Self.since(h.bleStateChangedAt)))
            conn.append(Row(label: "Signal (RSSI)", value: Self.dbm(h.rssi)))
        } else {
            conn.append(Row(label: "Head tracker", value: "Device orientation"))
        }
        conn.append(Row(label: "Last heartbeat", value: Self.age(h.lastHeartbeatAt)))
        out.append(Section(title: "Connectivity", rows: conn))

        // Device health
        out.append(Section(title: "Head-tracker device", rows: [
            Row(label: "Battery", value: Self.battery(mv: h.batteryMv)),
            Row(label: "Firmware", value: h.fwVersion ?? "—"),
            Row(label: "Uptime", value: Self.uptime(h.uptimeMs))
        ]))

        // IMU (live orientation read straight from the head-tracker globals)
        var imu: [Row] = [
            Row(label: "Azimuth", value: "\(hero.azimuth)°"),
            Row(label: "Elevation", value: "\(hero.elevation)°"),
            Row(label: "Steps", value: "\(hero.stepCount)")
        ]
        if let c = h.imuCalibStatus { imu.append(Row(label: "Calibration", value: "\(c)")) }
        if let r = h.imuReportRateHz { imu.append(Row(label: "Report rate", value: String(format: "%.0f Hz", r))) }
        out.append(Section(title: "Motion data", rows: imu))

        // Correction link (ESP32 -> hotspot -> NTRIP caster).
        out.append(Section(title: "Correction link", rows: [
            Row(label: "WiFi signal", value: Self.dbm(h.wifiRssi)),
            Row(label: "NTRIP", value: Self.bool(h.ntripConnected, on: "Connected", off: "Disconnected"))
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
            Row(label: "Correction age", value: Self.corrAge(h.corrAgeMs)),
            Row(label: "Last fix", value: Self.age(h.lastFixAt))
        ]))

        // Versions
        out.append(Section(title: "Versions", rows: [
            Row(label: "App", value: DeviceHealth.appVersion),
            Row(label: "Git commit", value: DeviceHealth.gitCommitHash),
            // Row(label: "Device ID", value: TelemetryService.fshared.config.deviceId ?? "—") // Revise telemetry implementation into app
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

    private static func bool(_ v: Bool?, on: String, off: String) -> String {
        guard let v = v else { return "—" }
        return v ? on : off
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

    private static func shortId(_ id: String?) -> String {
        guard let id = id else { return "—" }
        return String(id.prefix(8))
    }
}
