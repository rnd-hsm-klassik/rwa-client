//
//  TelemetrySource.swift
//  rwa client
//
//  Where the data in a telemetry event stems from (PROJECT-PLAN.md §1.1 /
//  §4.2). Present on every event as the wire field "source". This is
//  provenance only — every event reaches the backend through the app, so
//  "who sent it" is not what this says. Whether a record was *created* on
//  the assembly's firmware is visible from its dev_seq / t_dev_ms fields.
//
//  CROSS-REPO CONTRACT: the raw values are stored in the backend and used
//  in dashboard filters; never rename one, add new cases instead.
//

import Foundation

enum TelemetrySource: String {
    /// The RTK headtracker assembly (firmware rtk-rover): GNSS fixes,
    /// heading/IMU, and the firmware's own health events.
    case rtkHeadtracker = "rtk_headtracker"
    /// A plain headtracker assembly (firmware RWAHT): heading/IMU only.
    case headtracker = "headtracker"
    /// The phone itself: CoreLocation, CoreMotion, battery, app lifecycle.
    case phone = "phone"
    /// The RWA Creator simulator, driving the hero over OSC.
    case creator = "creator"

    /// The wire field name (§4.2).
    static let fieldName = "source"
}

/// Kind of the headset assembly currently connected over BLE. Decided once
/// at connect from GATT discovery (§5.1): the plain headtracker exposes only
/// the tracker characteristic 713D0002, the RTK headtracker additionally
/// exposes the raw position characteristic 713D0004 and the telemetry
/// service 713D0100. Not derivable from the BLE name or from data freshness.
enum AssemblyKind {
    case rtkHeadtracker
    case headtracker

    /// The `source` value for data this assembly produces.
    var telemetrySource: TelemetrySource {
        switch self {
        case .rtkHeadtracker: return .rtkHeadtracker
        case .headtracker: return .headtracker
        }
    }
}
