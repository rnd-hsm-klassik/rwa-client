//
//  PositioningPolicy.swift
//  rwa client
//
//  The positioning policy of the main path (runtime): when does the RTK
//  headtracker's feed count as alive, and therefore drive the hero, and when
//  does internal GPS take over.
//
//  This is single definition that CoreLocationController (hero fallback),
//  ControlViewController ("(RTK)" tag), MapViewController (marker tint) and
//  AppTelemetrySampler (attribution; the telemetry side only *observes* this
//  policy) all follow.
//

import Foundation

enum PositioningPolicy {

    /// How recent tracker data must be to count as the active source.
    static let freshnessWindow: TimeInterval = 8.0

    /// True while the tracker's coordinates are the active positioning
    /// source: selected in Settings, delivering within the freshness window,
    /// and not overridden by OSC registration. Says nothing about whether
    /// those coordinates are RTK-corrected; see trackerFixQuality().
    static func rtkTrackerActive() -> Bool {
        guard useRtkGps, !registered else { return false }
        guard let at = ubloxUpdatedAt else { return false }
        return Date().timeIntervalSince(at) < freshnessWindow
    }

    /// What "RTK" may mean in the UI while the tracker drives the hero.
    enum TrackerFixQuality {
        case rtkFixed     // carr_soln 2: centimetre-level
        case rtkFloat     // carr_soln 1: corrections applied, ambiguities not yet fixed
        case noRtk        // tracker position without corrections (or no fresh fix report)

        /// Suffix for the coordinate readout; only RTK is called RTK.
        var label: String {
            switch self {
            case .rtkFixed: return "RTK fixed"
            case .rtkFloat: return "RTK float"
            case .noRtk: return "tracker, no RTK"
            }
        }
        var isRtk: Bool { return self != .noRtk }
    }

    /// The tracker's current fix quality from the firmware's gnss_fix
    /// (carr_soln, 1 Hz, cached in DeviceHealth), or nil while the tracker is
    /// not the active source. A stale fix report (older than the freshness
    /// window) counts as no RTK: the label must never outlive the corrections.
    static func trackerFixQuality() -> TrackerFixQuality? {
        guard rtkTrackerActive() else { return nil }
        let health = DeviceHealth.shared.snapshot
        guard let at = health.lastFixAt,
              Date().timeIntervalSince(at) < freshnessWindow,
              let carrSoln = health.carrSoln else { return .noRtk }
        switch carrSoln {
        case 2: return .rtkFixed
        case 1: return .rtkFloat
        default: return .noRtk
        }
    }
}
