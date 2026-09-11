//
//  CasterSettings.swift
//  RWA Player
//
//  NTRIP caster settings (ADR-001, PROJECT-PLAN.md §6 item 6). Since
//  rtk-rover 0.48.0 the app is the NTRIP client, so the caster facts the
//  firmware used to embed per unit live here: in UserDefaults next to the
//  unit label, typed in Settings ▸ Caster or provisioned through
//  player-settings.plist (ProvisioningLoader). The username is per unit
//  (single-session accounts); host, port, mount point and password are
//  shared across the fleet. Kiosk phones we own: the password stays in
//  UserDefaults; move it to the Keychain if that ever changes.
//

import Foundation

struct CasterSettings: Equatable {

    static let defaultPort: UInt16 = 2101

    /// Posted (on main) by the Settings tab after any caster field changed;
    /// the NTRIP client's owner restarts the session on it.
    static let didChange = Notification.Name("CasterSettingsDidChange")

    var host = ""
    var port: UInt16 = CasterSettings.defaultPort
    var mount = ""
    var user = ""
    var pass = ""

    /// Everything a session needs. An empty password is allowed (sent as
    /// "user:"); host, port, mount point and username are not optional.
    var isComplete: Bool {
        return !host.isEmpty && port > 0 && !mount.isEmpty && !user.isEmpty
    }

    /// "host:port/mount" for Diagnostics and logs. Never the credentials.
    var endpointDescription: String {
        return "\(host):\(port)/\(mount)"
    }

    static func load(from defaults: UserDefaults = .standard) -> CasterSettings {
        var settings = CasterSettings()
        settings.host = trimmed(defaults.string(forKey: defaultsKeys.casterHost))
        settings.port = parsePort(defaults.string(forKey: defaultsKeys.casterPort))
        settings.mount = mountPoint(defaults.string(forKey: defaultsKeys.casterMount))
        settings.user = trimmed(defaults.string(forKey: defaultsKeys.casterUser))
        settings.pass = defaults.string(forKey: defaultsKeys.casterPass) ?? ""
        return settings
    }

    /// Empty → the NTRIP default 2101; unparsable → 0 (incomplete).
    static func parsePort(_ text: String?) -> UInt16 {
        let t = trimmed(text)
        if t.isEmpty { return defaultPort }
        return UInt16(t) ?? 0
    }

    /// The request line is `GET /<mount>`, so a leading slash typed by the
    /// operator is dropped rather than doubled.
    static func mountPoint(_ text: String?) -> String {
        var t = trimmed(text)
        while t.hasPrefix("/") { t.removeFirst() }
        return t
    }

    private static func trimmed(_ text: String?) -> String {
        return (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
