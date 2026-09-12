//
//  SettingsViewController.swift
//  rwa client
//
//  Settings tab: a grouped table (same style as the Diagnostics tab) that
//  consolidates the app's configuration. Values are stored in UserDefaults
//  under the existing defaultsKeys and mirrored into the app globals, which
//  is what the rest of the (globals-driven) app reads.
//
//  This is now the only place these settings live: the Control Data tab that
//  used to duplicate them was replaced by the actions-only Control tab.
//
//  Sections:
//    Identity      - unit ID (device_id in telemetry), headset assembly override
//    Caster        - NTRIP caster host / port / mount point / username / password
//                    (ADR-001: the app is the NTRIP client for the RTK headtracker)
//    Data sources  - GPS (internal / RTK headtracker), heading (internal / assembly)
//    Head tracking - inverse elevation, calibrate on start
//    RWA Creator   - IP address, register/unregister, forward GPS to Creator
//    Soundwalk     - default game (drill-in picker)
//

import UIKit

class SettingsViewController: UITableViewController, UITextFieldDelegate {

    private enum FieldTag: Int {
        case deviceId = 1
        case trackerName = 2
        case creatorIP = 3
        case gpsSource = 10
        case headingSource = 11
        case inverseElevation = 20
        case calibrateOnStart = 21
        case sendGPS2Creator = 22
        case casterHost = 30
        case casterPort = 31
        case casterMount = 32
        case casterUser = 33
        case casterPass = 34

        /// The UserDefaults key behind a caster field.
        var casterDefaultsKey: String? {
            switch self {
            case .casterHost: return defaultsKeys.casterHost
            case .casterPort: return defaultsKeys.casterPort
            case .casterMount: return defaultsKeys.casterMount
            case .casterUser: return defaultsKeys.casterUser
            case .casterPass: return defaultsKeys.casterPass
            default: return nil
            }
        }
    }

    private enum Section: Int {
        case identity = 0, caster, dataSources, headTracking, creator, soundwalk
        static let count = 6

        var title: String {
            switch self {
            case .identity: return "Identity"
            case .caster: return "Caster"
            case .dataSources: return "Data sources"
            case .headTracking: return "Head tracking"
            case .creator: return "RWA Creator"
            case .soundwalk: return "Soundwalk"
            }
        }

        var rowCount: Int {
            switch self {
            case .identity: return 2
            case .caster: return 5
            case .dataSources: return 2
            case .headTracking: return 2
            case .creator: return 3
            case .soundwalk: return 1
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    // MARK: - Table structure

    override func numberOfSections(in tableView: UITableView) -> Int {
        return Section.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return Section(rawValue: section)?.title
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .some(.identity):
            if let override = TelemetryService.shared?.config.unitIdOverride, !override.isEmpty {
                return "Unit ID is currently overridden by Telemetry.plist (\"\(override)\")."
            }
            return "The Unit ID identifies this unit (phone + headset assembly) in telemetry; by convention it is also the assembly's Bluetooth name. Set Headset assembly only to connect to a different assembly (a spare, or a plain headtracker)."
        case .some(.caster):
            return "NTRIP caster for RTK corrections."
        case .some(.dataSources):
            return "With RTK selected, the app falls back to internal GPS while the RTK headtracker delivers no coordinates."
        case .some(.creator):
            return "Toggle Register to listen for location data from RWA Creator. GPS forwarding sends this device's position to RWA Creator (while not registered)."
        default:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return Section(rawValue: section)?.rowCount ?? 0
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let section = Section(rawValue: indexPath.section) else { return UITableViewCell() }
        let defaults = UserDefaults.standard
        switch (section, indexPath.row) {
        case (.identity, 0):
            return textFieldCell(label: "Unit ID", value: deviceId,
                                 placeholder: "e.g. rwa-hs-3", tag: .deviceId)
        case (.identity, 1):
            return textFieldCell(label: "Headset assembly", value: headtrackerID,
                                 placeholder: "empty = Unit ID", tag: .trackerName)
        // Caster fields show what is stored, verbatim; CasterSettings
        // normalises (default port, leading slash) when the client reads them.
        case (.caster, 0):
            return textFieldCell(label: "Host", value: defaults.string(forKey: defaultsKeys.casterHost) ?? "",
                                 placeholder: "caster host", tag: .casterHost, keyboard: .URL)
        case (.caster, 1):
            return textFieldCell(label: "Port", value: defaults.string(forKey: defaultsKeys.casterPort) ?? "",
                                 placeholder: "\(CasterSettings.defaultPort)", tag: .casterPort, keyboard: .numberPad)
        case (.caster, 2):
            return textFieldCell(label: "Mount point", value: defaults.string(forKey: defaultsKeys.casterMount) ?? "",
                                 placeholder: "mount point", tag: .casterMount)
        case (.caster, 3):
            return textFieldCell(label: "Username", value: defaults.string(forKey: defaultsKeys.casterUser) ?? "",
                                 placeholder: "one per unit", tag: .casterUser)
        case (.caster, 4):
            return textFieldCell(label: "Password", value: defaults.string(forKey: defaultsKeys.casterPass) ?? "",
                                 placeholder: "password", tag: .casterPass, secure: true)
        case (.dataSources, 0):
            return segmentedCell(label: "GPS", options: ["Internal", "RTK tracker"],
                                 selectedIndex: useRtkGps ? 1 : 0, tag: .gpsSource)
        case (.dataSources, 1):
            return segmentedCell(label: "Heading", options: ["Internal", "Assembly"],
                                 selectedIndex: useHeadTracker ? 1 : 0, tag: .headingSource)
        case (.headTracking, 0):
            return switchCell(label: "Inverse elevation", isOn: inverseElevation, tag: .inverseElevation)
        case (.headTracking, 1):
            return switchCell(label: "Calibrate on start", isOn: calibrateOnStart, tag: .calibrateOnStart)
        case (.creator, 0):
            return textFieldCell(label: "IP address", value: rwaCreatorIP,
                                 placeholder: "192.168.0.1", tag: .creatorIP,
                                 keyboard: .numbersAndPunctuation)
        case (.creator, 1):
            return actionCell(title: registered ? "Unregister" : "Register")
        case (.creator, 2):
            return switchCell(label: "Send GPS to Creator", isOn: sendGPS2Creator, tag: .sendGPS2Creator)
        case (.soundwalk, 0):
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = "Default game"
            let name = (defaultGame as NSString).lastPathComponent
            cell.detailTextLabel?.text = defaultGame.isEmpty ? "None" : name
            cell.accessoryType = .disclosureIndicator
            return cell
        default:
            return UITableViewCell()
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath == IndexPath(row: 1, section: Section.creator.rawValue) {
            // Live action, not a stored setting: announce/withdraw this device
            // to rwaCreator. Only the cell's own title depends on the result,
            // so just refresh that row.
            toggleCreatorRegistration()
            tableView.reloadRows(at: [indexPath], with: .none)
        }
        if indexPath.section == Section.soundwalk.rawValue {
            navigationController?.pushViewController(DefaultGamePickerViewController(style: .grouped), animated: true)
        }
    }

    // MARK: - Cell builders

    private func textFieldCell(label: String, value: String, placeholder: String,
                               tag: FieldTag, keyboard: UIKeyboardType = .default,
                               secure: Bool = false) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.textLabel?.text = label

        let field = UITextField(frame: CGRect(x: 0, y: 0, width: 170, height: 30))
        field.text = value
        field.placeholder = placeholder
        field.textAlignment = .right
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.returnKeyType = .done
        field.keyboardType = keyboard
        field.isSecureTextEntry = secure
        field.delegate = self
        field.tag = tag.rawValue
        field.addTarget(self, action: #selector(fieldEditingEnded(_:)), for: .editingDidEnd)
        cell.accessoryView = field
        return cell
    }

    private func segmentedCell(label: String, options: [String], selectedIndex: Int,
                               tag: FieldTag) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.textLabel?.text = label

        let segmented = UISegmentedControl(items: options)
        segmented.selectedSegmentIndex = selectedIndex
        segmented.tag = tag.rawValue
        segmented.addTarget(self, action: #selector(segmentChanged(_:)), for: .valueChanged)
        cell.accessoryView = segmented
        return cell
    }

    /// A tappable, button-styled row (centered tint-coloured title), for
    /// actions rather than stored values — handled in didSelectRowAt.
    private func actionCell(title: String) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.text = title
        cell.textLabel?.textColor = .tintColor
        cell.textLabel?.textAlignment = .center
        return cell
    }

    private func switchCell(label: String, isOn: Bool, tag: FieldTag) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.textLabel?.text = label

        let control = UISwitch(frame: .zero)
        control.isOn = isOn
        control.tag = tag.rawValue
        control.addTarget(self, action: #selector(switchChanged(_:)), for: .valueChanged)
        cell.accessoryView = control
        return cell
    }

    // MARK: - Change handlers

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    @objc private func fieldEditingEnded(_ field: UITextField) {
        let defaults = UserDefaults.standard
        let text = (field.text ?? "").trimmingCharacters(in: .whitespaces)
        switch FieldTag(rawValue: field.tag) {
        case .some(.deviceId):
            let targetChanged = headtrackerID.isEmpty && text != deviceId
            deviceId = text
            defaults.set(text, forKey: defaultsKeys.unitId)
            // Without an assembly override the unit label is the BLE target.
            if targetChanged {
                NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Connect Headtracker"), object: nil)
            }
        case .some(.trackerName):
            if text != headtrackerID {
                headtrackerID = text
                defaults.set(text, forKey: defaultsKeys.assemblyId)
                NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Connect Headtracker"), object: nil)
            }
        case .some(.creatorIP):
            rwaCreatorIP = text
            defaults.set(text, forKey: defaultsKeys.rwaCreatorIP)
            // Keep an already-configured OSC client in sync; otherwise it
            // sends to the old address until the next register toggle.
            oscClient.host = text
        case .some(let tag) where tag.casterDefaultsKey != nil:
            // Stored verbatim (the password untrimmed: it may contain
            // spaces); CasterSettings normalises on read. Only a real
            // change restarts the caster session, and one field at a time:
            // the client's owner debounces the restarts.
            let key = tag.casterDefaultsKey!
            let value = tag == .casterPass ? (field.text ?? "") : text
            if (defaults.string(forKey: key) ?? "") != value {
                defaults.set(value, forKey: key)
                NotificationCenter.default.post(name: CasterSettings.didChange, object: nil)
            }
        default:
            break
        }
    }

    @objc private func segmentChanged(_ segmented: UISegmentedControl) {
        let defaults = UserDefaults.standard
        switch FieldTag(rawValue: segmented.tag) {
        case .some(.gpsSource):
            useRtkGps = segmented.selectedSegmentIndex == 1
            defaults.set(useRtkGps ? "rtk" : "internal", forKey: defaultsKeys.gpsSource)
            // BLE is needed (or no longer needed) depending on this too:
            // rtk positioning works with Internal heading selected.
            NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Connect Headtracker"), object: nil)
        case .some(.headingSource):
            useHeadTracker = segmented.selectedSegmentIndex == 1
            // Legacy string format, matches the existing readers
            defaults.set(useHeadTracker ? "true" : "false", forKey: defaultsKeys.useHeadtracker)
            NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Connect Headtracker"), object: nil)
        default:
            break
        }
    }

    @objc private func switchChanged(_ control: UISwitch) {
        let defaults = UserDefaults.standard
        switch FieldTag(rawValue: control.tag) {
        case .some(.inverseElevation):
            inverseElevation = control.isOn
            defaults.set(control.isOn ? "true" : "false", forKey: defaultsKeys.inverseElevation)
        case .some(.calibrateOnStart):
            calibrateOnStart = control.isOn
            defaults.set(control.isOn ? "true" : "false", forKey: defaultsKeys.calibrateOnStart)
        case .some(.sendGPS2Creator):
            // Session-only by design: not persisted, off again on relaunch
            sendGPS2Creator = control.isOn
        default:
            break
        }
    }
}

// MARK: - Default game picker

/// Drill-in list of the downloaded games (same scan the Games tab uses),
/// plus "None". Stores the Documents-relative name (e.g.
/// "hei-guide/hei-guide.rwa"): the absolute Documents path embeds the app
/// container UUID, which changes on every update/reinstall and used to
/// invalidate the stored default silently.
class DefaultGamePickerViewController: UITableViewController {

    private let games = GameManager()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Default game"
        games.populateGames()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return games.rwaGames.count + 1
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        if indexPath.row == 0 {
            cell.textLabel?.text = "None"
            cell.accessoryType = defaultGame.isEmpty ? .checkmark : .none
        } else {
            let game = games.rwaGames[indexPath.row - 1]
            cell.textLabel?.text = game.name
            cell.accessoryType = (defaultGame == game.name) ? .checkmark : .none
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if indexPath.row == 0 {
            defaultGame = ""
        } else {
            let game = games.rwaGames[indexPath.row - 1]
            defaultGame = game.name
        }
        UserDefaults.standard.set(defaultGame, forKey: defaultsKeys.defaultGame)
        tableView.reloadData()
        navigationController?.popViewController(animated: true)
    }
}
