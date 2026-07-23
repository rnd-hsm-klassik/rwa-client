//
//  ControlViewController.swift
//  rwa client
//
//  Operator control tab — the live-actions half of the old "Control Data"
//  screen. Everything that was configuration (Creator IP, headtracker name,
//  heading source, inverse elevation, calibrate on start, GPS forwarding)
//  moved to the Settings tab; the read-only sensor dumps moved to
//  Diagnostics. What is left here are the things that act on the *running*
//  app: start/stop the walk, connect the headtracker, calibrate north,
//  register with rwaCreator, and set the output volume — plus a compact
//  status readout so the operator does not have to switch tabs mid-walk.
//
//  Laid out in code and installed programmatically from
//  AppDelegate.installControlTab(), same pattern as the Diagnostics and
//  Settings tabs. The storyboard's "Control Data" scene is retired at
//  runtime (AppDelegate.hideControlDataTab()) and is no longer reachable.
//
//  This controller also carries over the OSC receiver duty from
//  ControlDataViewController: while it is visible it is the
//  F53OSCPacketDestination for rwaCreator's /step, /lon, /lat and
//  /currentscene messages. That is service work living in a view
//  controller, exactly like SecondViewController's BLE ownership — it is
//  kept as-is here and belongs to the planned service extraction, not to
//  this migration.
//

import UIKit

class ControlViewController: UIViewController, F53OSCPacketDestination {

    private var timer: Timer?

    private let projectLabel = UILabel()
    private let sceneLabel = UILabel()
    private let coordsLabel = UILabel()
    private let gpsDot = UIView()
    private let motionLabel = UILabel()
    private let gpsDotIdleColor = UIColor.systemGray4

    // Last fix marker seen by the poll tick, per positioning source —
    // a change means fresh GPS data and triggers the dot flash.
    private var seenUbloxFixAt: Date?
    private var seenLocationFixAt: Date?
    private var seenOscCoordinate: (lat: Double, lon: Double)?

    private let startStopButton = UIButton(type: .system)
    private let connectButton = UIButton(type: .system)
    private let calibrateButton = UIButton(type: .system)
    private let volumeSlider = UISlider()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Control"
        view.backgroundColor = .systemGroupedBackground
        buildInterface()
        // Reflect the global the audio engine actually uses (pdGain sends
        // slider * 5), instead of the old tab's hardcoded 0.5 which did not
        // match pdGainVal's default and silently jumped the volume on the
        // first touch.
        volumeSlider.value = min(max(pdGainVal / 5.0, 0), 1)
        updateButtons()
        NotificationCenter.default.addObserver(self, selector: #selector(self.updateButtons),
                                               name: NSNotification.Name(rawValue: "Update Buttons"),
                                               object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        oscServer.port = 8000
        oscServer.delegate = self
        oscClient.port = 8000
        timer = Timer.scheduledTimer(timeInterval: 0.25, target: self, selector: #selector(update),
                                     userInfo: nil, repeats: true)
        if(registered) {
            startOscListening()
        }
        // Don't blink for fixes that arrived while the tab was away
        seenUbloxFixAt = nil
        seenLocationFixAt = nil
        seenOscCoordinate = nil
        updateButtons()
        update()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timer?.invalidate()
        timer = nil
        if(registered) {
            oscServer.stopListening()
        }
    }

    // MARK: - Interface

    private func buildInterface() {
        // Loaded RWA project (soundwalk) filename, titling the status card
        projectLabel.font = UIFont.systemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .title3).pointSize, weight: .semibold)
        projectLabel.adjustsFontSizeToFitWidth = true
        projectLabel.minimumScaleFactor = 0.7

        let statusCard = makeStatusCard()

        style(startStopButton, prominent: true)
        style(connectButton)
        style(calibrateButton)
        calibrateButton.setTitle("Calibrate north", for: UIControlState())

        startStopButton.addTarget(self, action: #selector(start(_:)), for: .touchUpInside)
        connectButton.addTarget(self, action: #selector(bleConnect(_:)), for: .touchUpInside)
        calibrateButton.addTarget(self, action: #selector(calibrateHeadtracker(_:)), for: .touchUpInside)

        let volumeLabel = makeSectionLabel("Volume")

        // rwaCreator registration lives in Settings (below the Creator IP);
        // this tab keeps only the actions performed during a running walk.
        let stack = UIStackView(arrangedSubviews: [
            projectLabel,
            statusCard,
            connectButton,
            calibrateButton,
            startStopButton,
            volumeLabel,
            makeVolumeRow()
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(20, after: projectLabel)
        stack.setCustomSpacing(30, after: statusCard)
        stack.setCustomSpacing(30, after: calibrateButton)
        stack.setCustomSpacing(6, after: volumeLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Scroll view so the stack never has to compress on small screens in
        // landscape — keeps the layout unambiguous at every size.
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .onDrag
        scrollView.addSubview(stack)
        view.addSubview(scrollView)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: guide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: guide.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32)
        ])
    }

    /// Compact live readout: current scene/state on top, head-tracker motion
    /// below. Diagnostics shows the full picture; this is the glance version.
    private func makeStatusCard() -> UIView {
        let card = UIView()
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 10
        card.layer.masksToBounds = true

        sceneLabel.font = UIFont.preferredFont(forTextStyle: .headline)
        sceneLabel.textColor = .label
        sceneLabel.adjustsFontSizeToFitWidth = true
        sceneLabel.minimumScaleFactor = 0.7

        // Monospaced digits keep the line (and the dot after it) from
        // jittering as coordinate digits change.
        coordsLabel.font = UIFont.monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
        coordsLabel.textColor = .secondaryLabel

        gpsDot.backgroundColor = gpsDotIdleColor
        gpsDot.layer.cornerRadius = 4
        gpsDot.translatesAutoresizingMaskIntoConstraints = false
        gpsDot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        gpsDot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        // Spacer keeps the dot snug against the text end instead of at the
        // card's far edge.
        let spacer = UIView()
        spacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        let coordsRow = UIStackView(arrangedSubviews: [coordsLabel, gpsDot, spacer])
        coordsRow.axis = .horizontal
        coordsRow.spacing = 6
        coordsRow.alignment = .center

        motionLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        motionLabel.textColor = .secondaryLabel

        let inner = UIStackView(arrangedSubviews: [sceneLabel, coordsRow, motionLabel])
        inner.axis = .vertical
        inner.spacing = 2
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)

        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14)
        ])
        return card
    }

    private func makeVolumeRow() -> UIView {
        volumeSlider.minimumValue = 0
        volumeSlider.maximumValue = 1
        volumeSlider.addTarget(self, action: #selector(pdGain(_:)), for: .valueChanged)

        let row = UIView()
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(volumeSlider)
        NSLayoutConstraint.activate([
            volumeSlider.topAnchor.constraint(equalTo: row.topAnchor, constant: 4),
            volumeSlider.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -4),
            volumeSlider.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            volumeSlider.trailingAnchor.constraint(equalTo: row.trailingAnchor)
        ])
        return row
    }

    private func makeSectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text.uppercased()
        label.font = UIFont.preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel
        return label
    }

    private func style(_ button: UIButton, prominent: Bool = false) {
        button.titleLabel?.font = UIFont.preferredFont(forTextStyle: prominent ? .headline : .body)
        button.backgroundColor = prominent ? .systemBlue : .secondarySystemGroupedBackground
        button.setTitleColor(prominent ? .white : .systemBlue, for: UIControlState())
        // Explicit .normal colours defeat the system's automatic dimming
        button.setTitleColor(.tertiaryLabel, for: .disabled)
        button.layer.cornerRadius = 10
        button.layer.masksToBounds = true
        button.heightAnchor.constraint(equalToConstant: prominent ? 54 : 46).isActive = true
    }

    // MARK: - Live updates

    @objc func update() {
        DispatchQueue.main.async() {
            // currentGame is a full path when launched via the default game,
            // a relative name when picked from the Games list
            let project = (currentGame as NSString).lastPathComponent
            self.projectLabel.text = project.isEmpty ? "No project loaded" : project
            self.projectLabel.textColor = project.isEmpty ? .secondaryLabel : .label

            let scene = hero.currentScene?.name ?? "—"
            let state = hero.currentState?.stateName ?? "—"
            self.sceneLabel.text = "\(scene) · \(state)"
            self.motionLabel.text = "az \(hero.azimuth)°   el \(hero.elevation)°   \(hero.stepCount) steps"
            self.updateCoordinates()
        }
    }

    /// WGS84 position driving the walk, tagged "(RTK)" while the tracker's
    /// RTK coordinates are the active source: selected in Settings,
    /// delivering within the freshness window, and not overridden by OSC
    /// registration — same priority as CoreLocationController.
    private func updateCoordinates() {
        let rtkFresh = ubloxUpdatedAt.map {
            Date().timeIntervalSince($0) < LiveTelemetrySource.freshnessWindow } ?? false
        let rtkActive = useRtkGps && !registered && rtkFresh
        // %.5f ≈ 1 m resolution; enough to watch movement without the line
        // turning into a number wall.
        coordsLabel.text = String(format: "WGS84 %.5f, %.5f", hero.coordinates.latitude,
                                  hero.coordinates.longitude) + (rtkActive ? " (RTK)" : "")
        if fixArrivedSinceLastTick(rtkActive: rtkActive) {
            flashGpsDot()
        }
    }

    /// True when the active positioning source delivered a new fix since
    /// the previous poll tick.
    private func fixArrivedSinceLastTick(rtkActive: Bool) -> Bool {
        if registered {
            // OSC-sim coordinates carry no timestamp; a change is the signal.
            let current = (lat: hero.coordinates.latitude, lon: hero.coordinates.longitude)
            defer { seenOscCoordinate = current }
            guard let seen = seenOscCoordinate else { return false }
            return seen != current
        }
        if rtkActive, let at = ubloxUpdatedAt {
            defer { seenUbloxFixAt = at }
            return seenUbloxFixAt != nil && at != seenUbloxFixAt
        }
        // horizontalAccuracy < 0 marks the empty CLLocation() placeholder,
        // i.e. internal GPS has not delivered yet.
        if hero.location.horizontalAccuracy >= 0 {
            let at = hero.location.timestamp
            defer { seenLocationFixAt = at }
            return seenLocationFixAt != nil && at != seenLocationFixAt
        }
        return false
    }

    /// One green pulse that decays back to idle before the next 1 Hz fix,
    /// so consecutive fixes read as distinct blinks.
    private func flashGpsDot() {
        gpsDot.layer.removeAllAnimations()
        gpsDot.backgroundColor = .systemGreen
        UIView.animate(withDuration: 0.5, delay: 0.15, options: [],
                       animations: { self.gpsDot.backgroundColor = self.gpsDotIdleColor },
                       completion: nil)
    }

    @objc func updateButtons() {
        updateStartStopButton()
        updateConnectBleButton()
    }

    private func updateStartStopButton() {
        if(rwagameloop.isRunning) {
            startStopButton.setTitle("Stop", for: UIControlState())
            startStopButton.backgroundColor = .systemRed
        }
        else {
            startStopButton.setTitle("Start", for: UIControlState())
            startStopButton.backgroundColor = .systemBlue
        }
    }

    // Same titles the old Control Data / Current Scene tabs showed
    private func updateConnectBleButton() {
        if(headTrackerConnected) {
            if(useHeadTracker) {
                connectButton.setTitle("Headtracker connected", for: UIControlState()) }
            else {
                connectButton.setTitle("Using Device Orientation", for: UIControlState()) }
        }
        else {
            connectButton.setTitle("Connect Headtracker", for: UIControlState())
        }
        calibrateButton.isEnabled = headTrackerConnected
    }

    // MARK: - Actions

    @objc func start(_ sender: UIButton) {
        if(!rwagameloop.isRunning) {
            NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Start Game"), object: nil)
        }
        else {
            NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Stop Game"), object: nil)
        }
    }

    @objc func bleConnect(_ sender: UIButton) {
        if(!headTrackerConnected) {
            NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Connect Headtracker"), object: nil)
        }
    }

    @objc func calibrateHeadtracker(_ sender: UIButton) {
        if(headTrackerConnected)
        {
            azimuthOffset = azimuthOrg
            elevationOffset = elevationOrg
        }
    }

    @objc func pdGain(_ sender: UISlider) {
        pdGainVal = sender.value * 5.0
        PdBase.send(Float(pdGainVal), toReceiver: "rwamainvolume")
    }

    // MARK: - OSC

    func take(_ message: F53OSCMessage!)
    {
        if message.addressPattern == "/step"
        {
            if let _ = message.arguments.first as? Int {
                hero.stepCount = hero.stepCount + 1
                stepCount = stepCount + 1
                print("Received Step")
            }
        }

        if message.addressPattern == "/lon"
        {
            if let lon = message.arguments.first as? Double {
                hero.coordinates.longitude = lon
            }
        }

        if message.addressPattern == "/lat"
        {
            if let lat = message.arguments.first as? Double {
                hero.coordinates.latitude = lat
            }
        }

        if message.addressPattern == "/currentscene"
        {
            if var currentScene = message.arguments.first as? String {
                print(currentScene)

                let nextScene:RwaScene = hero.getScene(sceneName: currentScene)

                if(hero.currentScene != nextScene)
                {
                    rwagameloop.sendEnd2BackgroundAssets()
                    rwagameloop.sendEnd2ActiveAssets()
                    hero.currentScene = nextScene
                    if((hero.currentScene?.states.count)! > 0) {
                        hero.currentState = hero.currentScene?.states[0] }
                    hero.timeInCurrentState = 0
                    hero.timeInCurrentScene = 0
                    rwagameloop.startBackgroundState()
                    sceneChanged = true
                    currentScene = nextScene.name;
                    print("New Scene: \(String(describing: currentScene))")
                }
            }
        }
    }
}
