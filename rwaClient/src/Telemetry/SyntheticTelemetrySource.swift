//
//  SyntheticTelemetrySource.swift
//  rwa client
//
//  Debug-only stand-in for the BLE telemetry feed (PROJECT-PLAN.md §9.3):
//  emits plausible gnss_fix at 1 Hz and heartbeat every 15 s so the full
//  buffer -> batch -> upload -> dedup path runs without rtk-rover hardware.
//  Enabled via SyntheticSourceEnabled in Telemetry.plist.
//

import Foundation

class SyntheticTelemetrySource {

    static let fwVersion = "0.0.0+synthetic"

    private let service: TelemetryService
    private let queue = DispatchQueue(label: "ch.rwa.telemetry.synthetic", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var seq: UInt64 = 0
    private var tick: UInt64 = 0
    private let bootDate = Date()

    // Random walk around a fixed starting point (Basel area).
    private var lat = 47.534512
    private var lon = 7.605231

    init(service: TelemetryService) {
        self.service = service
    }

    func start() {
        service.updateFwVersion(SyntheticTelemetrySource.fwVersion)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
        t.setEventHandler { [weak self] in
            self?.handleTick()
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func handleTick() {
        tick += 1
        emitGnssFix()
        if tick % 15 == 0 {
            emitHeartbeat()
        }
    }

    private var uptimeMs: UInt32 {
        return UInt32(Date().timeIntervalSince(bootDate) * 1000)
    }

    private func emitGnssFix() {
        // ~0.5 m steps at walking pace
        lat += Double.random(in: -0.000005 ... 0.000005)
        lon += Double.random(in: -0.000007 ... 0.000007)

        // Mostly RTK fixed, occasionally degraded to float
        let rtkFixed = Int.random(in: 0 ..< 10) < 8
        seq += 1
        service.recordDeviceEvent([
            "seq": seq,
            "t_dev_ms": uptimeMs,
            "type": "gnss_fix",
            "lat": lat,
            "lon": lon,
            "height_m": 290.0 + Double.random(in: -1.5 ... 1.5),
            "fix_type": 3,
            "carr_soln": rtkFixed ? 2 : 1,
            "h_acc_mm": rtkFixed ? Int.random(in: 9 ... 25) : Int.random(in: 120 ... 900),
            "v_acc_mm": rtkFixed ? Int.random(in: 14 ... 40) : Int.random(in: 200 ... 1400),
            "num_sv": Int.random(in: 18 ... 28),
            "pdop": Double(Int.random(in: 10 ... 25)) / 10.0,
            "corr_age_ms": Int.random(in: 500 ... 3000)
        ])
    }

    private func emitHeartbeat() {
        seq += 1
        service.recordDeviceEvent([
            "seq": seq,
            "t_dev_ms": uptimeMs,
            "type": "heartbeat",
            "uptime_ms": uptimeMs,
            "free_heap": Int.random(in: 90_000 ... 140_000),
            "wifi_rssi": Int.random(in: -70 ... -50),
            "ntrip_connected": true,
            "fw_version": SyntheticTelemetrySource.fwVersion
        ])
    }
}
