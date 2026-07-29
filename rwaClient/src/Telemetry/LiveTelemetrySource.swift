//
//  LiveTelemetrySource.swift
//  rwa client
//
//  Live telemetry producer: samples the app's positioning state at 1 Hz
//  (the gnss_fix rate from PROJECT-PLAN.md §4.3) and emits a heartbeat
//  every 15 s. Deliberately a sampler, not a callback hook: the BLE /
//  CoreMotion / CoreLocation hot paths stay untouched (CLAUDE.md
//  constraint), we only read the globals they already maintain.
//
//  Every event carries an additive "source" field so the backend can
//  distinguish where the data came from:
//    position: "rtk_tracker" (BLE ublox frames) | "ios_gps" (CoreLocation)
//              | "osc_sim" (rwaCreator remote control)
//    heading:  "headtracker_rtk" | "headtracker" | "ios_motion"
//
//  All events are app-origin observations, so they use the app seq range
//  (§4.2); the device seq range stays reserved for the future CBOR feed.
//

import Foundation
import UIKit

final class LiveTelemetrySource {

    static let sampleInterval: TimeInterval = 1.0
    static let heartbeatEveryTicks: UInt64 = 15
    /// How recent tracker data must be to count as the active source.
    static let freshnessWindow: TimeInterval = 8.0

    /// True while the tracker's RTK coordinates are the active positioning
    /// source: selected in Settings, delivering within the freshness window,
    /// and not overridden by OSC registration. Single definition of the
    /// priority that CoreLocationController / ControlViewController / the
    /// map marker all follow.
    static func rtkTrackerActive() -> Bool {
        guard useRtkGps, !registered else { return false }
        guard let at = ubloxUpdatedAt else { return false }
        return Date().timeIntervalSince(at) < freshnessWindow
    }

    private let service: TelemetryService
    private let queue = DispatchQueue(label: "ch.rwa.telemetry.live", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var tick: UInt64 = 0
    private let startDate = Date()

    // Emit-only-on-new-data bookkeeping
    private var lastEmittedUbloxAt: Date?
    private var lastEmittedLocationAt: Date?
    private var lastEmittedOscLat: Double?
    private var lastEmittedOscLon: Double?

    private var lastPositionSource: String?
    private var lastHeadingSource: String?

    init(service: TelemetryService) {
        self.service = service
    }

    func start() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + LiveTelemetrySource.sampleInterval,
                   repeating: LiveTelemetrySource.sampleInterval)
        t.setEventHandler { [weak self] in
            self?.sample()
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Sampling (on own queue; reads app globals the same way the
    // rest of the codebase does, without extra synchronization)

    private func sample() {
        tick += 1

        if let (source, fields) = currentFix() {
            lastPositionSource = source
            service.recordAppOriginEvent(type: "gnss_fix", fields: fields)
            // Not mirrored into DeviceHealth: the fix fields there belong to
            // device-origin fixes only (they rejected sourced events anyway);
            // this sampler's contribution to Diagnostics is setLiveSources.
        }

        if let (source, fields) = currentHeading() {
            lastHeadingSource = source
            service.recordAppOriginEvent(type: "heading", fields: fields)
        } else {
            lastHeadingSource = nil
        }

        DeviceHealth.shared.setLiveSources(position: lastPositionSource,
                                           heading: lastHeadingSource)

        if tick % LiveTelemetrySource.heartbeatEveryTicks == 0 {
            emitHeartbeat()
        }
    }

    /// Best available position, or nil when nothing new arrived since the
    /// last emit — a positioning dropout should show up as a gap in the
    /// data, not as repeats of the last fix.
    private func currentFix() -> (String, [String: Any])? {
        let now = Date()

        // Mirrors the actual positioning priority: OSC-registered mode
        // overrides everything; then the RTK tracker when selected in
        // Settings and delivering; then internal GPS as fallback.

        // rwaCreator simulation drives hero.coordinates directly
        if registered {
            let lat = hero.coordinates.latitude
            let lon = hero.coordinates.longitude
            if lat == lastEmittedOscLat && lon == lastEmittedOscLon {
                return nil
            }
            lastEmittedOscLat = lat
            lastEmittedOscLon = lon
            return ("osc_sim", [
                "lat": lat,
                "lon": lon,
                "source": "osc_sim"
            ])
        }

        // RTK tracker positioning: selected in Settings and delivering
        if useRtkGps,
           let updatedAt = ubloxUpdatedAt,
           now.timeIntervalSince(updatedAt) < LiveTelemetrySource.freshnessWindow,
           let lat = ubloxLat, let lon = ubloxLon {
            if lastEmittedUbloxAt == updatedAt {
                return nil
            }
            lastEmittedUbloxAt = updatedAt
            // The current text protocol carries only lat/lon; accuracy,
            // carrier solution etc. arrive with the CBOR feed later.
            return ("rtk_tracker", [
                "lat": lat,
                "lon": lon,
                "source": "rtk_tracker"
            ])
        }

        // iOS GPS: hero.location is only ever written by CoreLocation.
        // horizontalAccuracy < 0 marks the empty CLLocation() placeholder.
        let location = hero.location
        if location.horizontalAccuracy >= 0 {
            if lastEmittedLocationAt == location.timestamp {
                return nil
            }
            lastEmittedLocationAt = location.timestamp
            var fields: [String: Any] = [
                "lat": location.coordinate.latitude,
                "lon": location.coordinate.longitude,
                "h_acc_mm": Int(location.horizontalAccuracy * 1000),
                "carr_soln": 0,
                "source": "ios_gps"
            ]
            if location.verticalAccuracy >= 0 {
                fields["height_m"] = location.altitude
                fields["v_acc_mm"] = Int(location.verticalAccuracy * 1000)
                fields["fix_type"] = 3
            } else {
                fields["fix_type"] = 2
            }
            return ("ios_gps", fields)
        }

        return nil
    }

    /// Current heading, or nil when no heading source is running.
    /// headTrackerConnected doubles as "CoreMotion started" in the
    /// device-orientation mode (see SecondViewController).
    private func currentHeading() -> (String, [String: Any])? {
        guard headTrackerConnected else { return nil }

        var fields: [String: Any] = [
            "azimuth": hero.azimuth,
            "elevation": hero.elevation,
            "step_count": hero.stepCount
        ]

        let source: String
        if useHeadTracker {
            let now = Date()
            let rtk = ubloxUpdatedAt.map { now.timeIntervalSince($0) < LiveTelemetrySource.freshnessWindow } ?? false
            source = rtk ? "headtracker_rtk" : "headtracker"
            fields["tracker_id"] = headtrackerID
        } else {
            source = "ios_motion"
        }
        fields["source"] = source
        return (source, fields)
    }

    private func emitHeartbeat() {
        var fields: [String: Any] = [
            "source": "ios_app",
            "uptime_ms": UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince(startDate) * 1000)),
            "tracker_connected": useHeadTracker && headTrackerConnected,
            "tracker_id": headtrackerID,
            "walk_running": rwagameloop.isRunning,
            "position_source": lastPositionSource ?? "none",
            "heading_source": lastHeadingSource ?? "none"
        ]

        let battery = UIDevice.current.batteryLevel
        if battery >= 0 {
            fields["batt_pct"] = Int(battery * 100)
        }
        if let rssi = DeviceHealth.shared.snapshot.rssi {
            fields["tracker_rssi"] = rssi
        }

        service.recordAppOriginEvent(type: "heartbeat", fields: fields)
    }
}
