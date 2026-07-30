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
//    Identity      - device ID (telemetry), headtracker name
//    Data sources  - GPS (internal / RTK headtracker), heading (internal / headtracker)
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
    }

    private let sectionTitles = ["Identity", "Data sources", "Head tracking", "RWA Creator", "Soundwalk"]

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
        return sectionTitles.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return sectionTitles[section]
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 {
            if let override = TelemetryService.shared?.config.deviceId, !override.isEmpty {
                return "Device ID is currently overridden by Telemetry.plist (\"\(override)\")."
            }
            return "The Device ID identifies this device for analytics. The Headtracker name is needs to be set to the Bluetooth name of the Headtracker to connect to."
        }
        if section == 1 {
            return "With RTK selected, the app falls back to internal GPS while the tracker delivers no coordinates."
        }
        if section == 3 {
            return "Toggle Register to listen for location data from RWA Creator. GPS forwarding sends this device's position to RWA Creator (while not registered)."
        }
        return nil
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 2
        case 1: return 2
        case 2: return 2
        case 3: return 3
        case 4: return 1
        default: return 0
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch (indexPath.section, indexPath.row) {
        case (0, 0):
            return textFieldCell(label: "Device ID", value: deviceId,
                                 placeholder: "e.g. hs-03", tag: .deviceId)
        case (0, 1):
            return textFieldCell(label: "Headtracker", value: headtrackerID,
                                 placeholder: "e.g. rwaht01", tag: .trackerName)
        case (1, 0):
            return segmentedCell(label: "GPS", options: ["Internal", "RTK tracker"],
                                 selectedIndex: useRtkGps ? 1 : 0, tag: .gpsSource)
        case (1, 1):
            return segmentedCell(label: "Heading", options: ["Internal", "Headtracker"],
                                 selectedIndex: useHeadTracker ? 1 : 0, tag: .headingSource)
        case (2, 0):
            return switchCell(label: "Inverse elevation", isOn: inverseElevation, tag: .inverseElevation)
        case (2, 1):
            return switchCell(label: "Calibrate on start", isOn: calibrateOnStart, tag: .calibrateOnStart)
        case (3, 0):
            return textFieldCell(label: "IP address", value: rwaCreatorIP,
                                 placeholder: "192.168.0.1", tag: .creatorIP,
                                 keyboard: .numbersAndPunctuation)
        case (3, 1):
            return actionCell(title: registered ? "Unregister" : "Register")
        case (3, 2):
            return switchCell(label: "Send GPS to Creator", isOn: sendGPS2Creator, tag: .sendGPS2Creator)
        case (4, 0):
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
        if indexPath == IndexPath(row: 1, section: 3) {
            // Live action, not a stored setting: announce/withdraw this device
            // to rwaCreator. Only the cell's own title depends on the result,
            // so just refresh that row.
            toggleCreatorRegistration()
            tableView.reloadRows(at: [indexPath], with: .none)
        }
        if indexPath.section == 4 {
            navigationController?.pushViewController(DefaultGamePickerViewController(style: .grouped), animated: true)
        }
    }

    // MARK: - Cell builders

    private func textFieldCell(label: String, value: String, placeholder: String,
                               tag: FieldTag, keyboard: UIKeyboardType = .default) -> UITableViewCell {
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
            deviceId = text
            defaults.set(text, forKey: defaultsKeys.deviceId)
        case .some(.trackerName):
            if text != headtrackerID {
                headtrackerID = text
                defaults.set(text, forKey: defaultsKeys.headtrackerId)
                NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Connect Headtracker"), object: nil)
            }
        case .some(.creatorIP):
            rwaCreatorIP = text
            defaults.set(text, forKey: defaultsKeys.rwaCreatorIP)
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
/// plus "None". Stores path + "/" + name, the format FirstViewController
/// reads on launch.
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
            cell.accessoryType = (defaultGame == game.path + "/" + game.name) ? .checkmark : .none
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if indexPath.row == 0 {
            defaultGame = ""
        } else {
            let game = games.rwaGames[indexPath.row - 1]
            defaultGame = game.path + "/" + game.name
        }
        UserDefaults.standard.set(defaultGame, forKey: defaultsKeys.defaultGame)
        tableView.reloadData()
        navigationController?.popViewController(animated: true)
    }
}
