//
//  AppTelemetrySampler.swift
//  rwa client
//
//  App-side telemetry producer (formerly LiveTelemetrySource): samples the
//  app's positioning state at 1 Hz (the gnss_fix rate from PROJECT-PLAN.md
//  §4.3) and emits an app heartbeat every 15 s. Deliberately a sampler, not
//  a set of callback hooks: the BLE / CoreMotion / CoreLocation hot paths
//  stay untouched (CLAUDE.md constraint), we only read the globals they
//  already maintain.
//
//  Every event carries `source` (TelemetrySource, §4.2): where the *data*
//  stems from. Events created here have no dev_seq / t_dev_ms; those mark
//  records created on the assembly's firmware.
//
//  One gnss_fix stream per source (§4.3):
//    - `rtk_headtracker` fixes are the firmware's own CBOR records; the
//      sampler never re-packages the text-protocol position.
//    - the `phone` stream (CoreLocation) is emitted CONTINUOUSLY, also
//      while the RTK headtracker drives the hero. This adds to the
//      dataset for comparing phone GPS against RTK over the same walk;
//      the backend separates the two by `source`.
//  Emission is therefore decoupled from attribution: which source *drives
//  the hero* is a separate statement, reported to Diagnostics
//  (DeviceHealth.setLiveSources) and as `position_source` in the app
//  heartbeat.
//
//  heading is always app-created (the firmware has no heading event type);
//  its source is the connected assembly's kind, or `phone` for CoreMotion.
//

import Foundation
import UIKit

final class AppTelemetrySampler {

    static let sampleInterval: TimeInterval = 1.0
    static let heartbeatEveryTicks: UInt64 = 15

    private let service: TelemetryService
    private let queue = DispatchQueue(label: "ch.rwa.telemetry.live", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var tick: UInt64 = 0
    private let startDate = Date()

    // Emit-only-on-new-data bookkeeping
    private var lastEmittedLocationAt: Date?
    private var lastEmittedOscLat: Double?
    private var lastEmittedOscLon: Double?

    private var lastPositionSource: TelemetrySource?
    private var lastHeadingSource: TelemetrySource?

    init(service: TelemetryService) {
        self.service = service
    }

    func start() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + AppTelemetrySampler.sampleInterval,
                   repeating: AppTelemetrySampler.sampleInterval)
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

        // Attribution: which source drives the hero right now.
        lastPositionSource = AppTelemetrySampler.activePositionSource()

        // Emission: every app-sampled stream that has new data, regardless
        // of which source drives the hero (see header).
        if var fields = newCreatorFix() {
            fields[TelemetrySource.fieldName] = TelemetrySource.creator.rawValue
            service.recordAppOriginEvent(type: "gnss_fix", fields: fields)
        }
        if var fields = newInternalFix() {
            fields[TelemetrySource.fieldName] = TelemetrySource.phone.rawValue
            service.recordAppOriginEvent(type: "gnss_fix", fields: fields)
            // Not mirrored into DeviceHealth: the fix fields there belong to
            // the firmware's fixes only; this sampler's contribution to
            // Diagnostics is setLiveSources.
        }

        if let (source, fields) = currentHeading() {
            lastHeadingSource = source
            service.recordAppOriginEvent(type: "heading", fields: fields)
        } else {
            lastHeadingSource = nil
        }

        DeviceHealth.shared.setLiveSources(position: lastPositionSource?.rawValue,
                                           heading: lastHeadingSource?.rawValue)

        if tick % AppTelemetrySampler.heartbeatEveryTicks == 0 {
            emitHeartbeat()
        }
    }

    /// Which source drives the hero right now.
    /// The attribution view of PositioningPolicy (which owns the actual
    /// priority: OSC-registered mode overrides everything; then the RTK tracker
    /// when selected in Settings and delivering; then internal GPS as
    /// fallback). nil when nothing delivers.
    static func activePositionSource() -> TelemetrySource? {
        if registered { return .creator }
        if PositioningPolicy.rtkTrackerActive() { return .rtkHeadtracker }
        if let at = locationUpdatedAt,
           Date().timeIntervalSince(at) < PositioningPolicy.freshnessWindow {
            return .phone
        }
        return nil
    }

    /// Fields of a Creator-simulated fix, or nil when not registered or the
    /// coordinates did not change. OSC positions carry no timestamp, so a
    /// change is the "new data" signal.
    private func newCreatorFix() -> [String: Any]? {
        guard registered else { return nil }
        let lat = hero.coordinates.latitude
        let lon = hero.coordinates.longitude
        if lat == lastEmittedOscLat && lon == lastEmittedOscLon {
            return nil
        }
        lastEmittedOscLat = lat
        lastEmittedOscLon = lon
        return ["lat": lat, "lon": lon]
    }

    /// Fields of the phone's own CoreLocation fix, or nil when CoreLocation
    /// delivered nothing new since the last emit. A dropout should show up
    /// as a gap in the data, not as repeats of the last fix.
    /// lastInternalLocation / locationUpdatedAt are set by
    /// CoreLocationController on every delivered fix, independent of what
    /// drives the hero; nil means CoreLocation has not delivered at all
    /// (the CLLocation() placeholder in hero.location must never be
    /// emitted, it reads as lat/lon 0).
    private func newInternalFix() -> [String: Any]? {
        guard let updatedAt = locationUpdatedAt, let location = lastInternalLocation,
              updatedAt != lastEmittedLocationAt else { return nil }
        lastEmittedLocationAt = updatedAt
        var fields: [String: Any] = [
            "lat": location.coordinate.latitude,
            "lon": location.coordinate.longitude,
            "h_acc_mm": Int(location.horizontalAccuracy * 1000),
            "carr_soln": 0
        ]
        if location.verticalAccuracy >= 0 {
            fields["height_m"] = location.altitude
            fields["v_acc_mm"] = Int(location.verticalAccuracy * 1000)
            fields["fix_type"] = 3
        } else {
            fields["fix_type"] = 2
        }
        return fields
    }

    /// Current heading, or nil when no heading source is running.
    /// headTrackerConnected doubles as "CoreMotion started" in the
    /// device-orientation mode (see SecondViewController).
    private func currentHeading() -> (TelemetrySource, [String: Any])? {
        guard headTrackerConnected else { return nil }

        var fields: [String: Any] = [
            "azimuth": hero.azimuth,
            "elevation": hero.elevation,
            "step_count": hero.stepCount
        ]

        let source: TelemetrySource
        if useHeadTracker {
            // The data comes from whatever assembly is connected; its kind
            // was decided from GATT at connect (AssemblyKind). Fall back to
            // the plain headtracker for the sample or two before discovery
            // has finished.
            let snapshot = DeviceHealth.shared.snapshot
            source = (snapshot.assemblyKind ?? .headtracker).telemetrySource
            fields["assembly_id"] = snapshot.assemblyId ?? headtrackerID
        } else {
            source = .phone
        }
        fields[TelemetrySource.fieldName] = source.rawValue
        return (source, fields)
    }

    private func emitHeartbeat() {
        let snapshot = DeviceHealth.shared.snapshot
        var fields: [String: Any] = [
            TelemetrySource.fieldName: TelemetrySource.phone.rawValue,
            "uptime_ms": UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince(startDate) * 1000)),
            "assembly_connected": useHeadTracker && headTrackerConnected,
            "walk_running": rwagameloop.isRunning,
            "position_source": lastPositionSource?.rawValue ?? "none",
            "heading_source": lastHeadingSource?.rawValue ?? "none"
        ]

        // The assembly actually connected (advertised BLE name captured at
        // discovery), not the Settings target, so a mismatch is visible.
        if let assemblyId = snapshot.assemblyId {
            fields["assembly_id"] = assemblyId
        }
        let battery = UIDevice.current.batteryLevel
        if battery >= 0 {
            fields["batt_pct"] = Int(battery * 100)
        }
        if let rssi = snapshot.rssi {
            fields["assembly_rssi"] = rssi
        }

        service.recordAppOriginEvent(type: "heartbeat", fields: fields)
    }
}
