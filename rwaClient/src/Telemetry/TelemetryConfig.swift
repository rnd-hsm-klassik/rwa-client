//
//  TelemetryConfig.swift
//  rwa client
//
//  Telemetry gateway configuration (PROJECT-PLAN.md §6).
//  Kiosk devices: device_id and ingest token come from a bundled plist,
//  not from user input or UserDefaults.
//

import Foundation

struct TelemetryConfig {
    /// Optional dev/simulator override; on real devices the ID comes from
    /// the Settings tab (see TelemetryService.currentDeviceId).
    let deviceId: String?
    let baseURL: URL
    let ingestToken: String
    let syntheticSourceEnabled: Bool

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

        let deviceId = (plist["DeviceId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let synthetic = plist["SyntheticSourceEnabled"] as? Bool ?? false
        return TelemetryConfig(deviceId: deviceId,
                               baseURL: baseURL,
                               ingestToken: ingestToken,
                               syntheticSourceEnabled: synthetic)
    }
}
