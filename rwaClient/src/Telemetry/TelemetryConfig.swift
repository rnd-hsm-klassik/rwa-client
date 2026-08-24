//
//  TelemetryConfig.swift
//  rwa client
//
//  Telemetry gateway configuration (PROJECT-PLAN.md §6).
//  Kiosk phones: backend URL and ingest token come from a bundled plist,
//  not from user input or UserDefaults.
//

import Foundation

struct TelemetryConfig {
    /// Optional dev/simulator override of the unit label (`device_id`); on
    /// real phones it comes from Settings -> Unit ID
    /// (TelemetryService.resolveDeviceId).
    let unitIdOverride: String?
    let baseURL: URL
    let ingestToken: String

    static func loadFromBundle() -> TelemetryConfig? {
        guard let url = Bundle.main.url(forResource: "Telemetry", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let baseURLString = plist["BaseURL"] as? String,
              let baseURL = URL(string: baseURLString),
              let ingestToken = plist["IngestToken"] as? String
        else {
            return nil
        }

        // "UnitId" is the v3 key (§1.1); "DeviceId" accepted as the pre-v3
        // spelling so existing local plists keep working.
        let unitIdOverride = ((plist["UnitId"] as? String) ?? (plist["DeviceId"] as? String))
            .flatMap { $0.isEmpty ? nil : $0 }
        return TelemetryConfig(unitIdOverride: unitIdOverride,
                               baseURL: baseURL,
                               ingestToken: ingestToken)
    }
}
