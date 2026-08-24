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

    /// True while the tracker's RTK coordinates are the active positioning
    /// source: selected in Settings, delivering within the freshness window,
    /// and not overridden by OSC registration.
    static func rtkTrackerActive() -> Bool {
        guard useRtkGps, !registered else { return false }
        guard let at = ubloxUpdatedAt else { return false }
        return Date().timeIntervalSince(at) < freshnessWindow
    }
}
