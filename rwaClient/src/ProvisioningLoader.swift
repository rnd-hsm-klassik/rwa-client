//
//  ProvisioningLoader.swift
//  RWA Player
//
//  Applies per-device operator settings pushed over USB into the app's
//  Documents folder (deploy_games.sh -s on the laptop) to UserDefaults.
//
//  The file is Documents/player-settings.plist, a dictionary of the keys in
//  keyMap below. It is applied once per file *content* at launch: operators
//  may still change settings on the phone afterwards, and a relaunch must not
//  revert them; pushing a changed plist applies again.
//

import Foundation

struct ProvisioningLoader {

    static let fileName = "player-settings.plist"
    static let appliedContentKey = "provisioningAppliedContent"

    // plist key -> UserDefaults key. Values are stored as strings, in the
    // same encodings the Settings tab writes; plist booleans are accepted
    // and mapped to "true"/"false".
    static let keyMap: [String: String] = [
        "deviceId": defaultsKeys.deviceId,
        "headtrackerId": defaultsKeys.headtrackerId,
        "creatorIP": defaultsKeys.rwaCreatorIP,
        "gpsSource": defaultsKeys.gpsSource,             // "internal" | "rtk"
        "useHeadtracker": defaultsKeys.useHeadtracker,   // "true" | "false"
        "inverseElevation": defaultsKeys.inverseElevation,
        "calibrateOnStart": defaultsKeys.calibrateOnStart,
        "defaultGame": defaultsKeys.defaultGame,         // Documents-relative .rwa path
    ]

    static func applyIfNeeded(defaults: UserDefaults) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = documents.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return }

        let content = String(data: data, encoding: .utf8) ?? data.base64EncodedString()
        if defaults.string(forKey: appliedContentKey) == content { return }

        guard let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else {
            logger.error("provisioning: \(fileName) is not a plist dictionary, ignoring")
            return
        }

        for (plistKey, defaultsKey) in keyMap {
            guard let value = plist[plistKey] else { continue }
            let stringValue: String
            if let boolValue = value as? Bool {
                stringValue = boolValue ? "true" : "false"
            } else {
                stringValue = "\(value)"
            }
            defaults.set(stringValue, forKey: defaultsKey)
            logger.info("provisioning: \(plistKey) = \(stringValue)")
        }
        for key in plist.keys where keyMap[key] == nil {
            logger.error("provisioning: unknown key '\(key)' ignored")
        }

        defaults.set(content, forKey: appliedContentKey)
        logger.info("provisioning: applied \(fileName)")
    }
}
