//
//  AppDelegate.swift
//  rwa client
//
//  Created by Admin on 28/12/15.
//  Copyright © 2015 beryllium design. All rights reserved.
//

import UIKit
import OSLog

let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "RWA Player", category: "Catch-All")

var coreLocationController:CoreLocationController?
var registered = false;
var headtrackerID = ""
var rwaCreatorIP = ""
// Telemetry device identity (Settings tab); empty = fall back to headtrackerID
var deviceId = ""
// Position from the RTK headtracker instead of internal GPS (Settings tab)
var useRtkGps = false
var inverseElevation = true;
// Session-only by design: always starts off, not persisted (Settings tab)
var sendGPS2Creator = false;
var oscClient = F53OSCClient.init()
var oscServer = F53OSCServer.init()

struct defaultsKeys {
    static let headtrackerId = "rwaht01"
    static let rwaCreatorIP = "192.168.178.53"
    static let inverseElevation = "true";
    static let useHeadtracker = "true";
    static let defaultGame = ""
    static let calibrateOnStart = "false"
    static let deviceId = "deviceId"
    static let gpsSource = "gpsSource"   // "internal" | "rtk"
}

@UIApplicationMain

class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    var audioController: PdAudioController?
    var liveTelemetry: LiveTelemetrySource?
    var currentSceneController: UIViewController?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplicationLaunchOptionsKey: Any]?) -> Bool
    {
        if let telemetryConfig = TelemetryConfig.loadFromBundle() {
            let telemetry = TelemetryService(config: telemetryConfig)
            TelemetryService.shared = telemetry
            telemetry.start()
            telemetry.recordAppEvent(name: "app_launched")
            let live = LiveTelemetrySource(service: telemetry)
            live.start()
            liveTelemetry = live
        }
        else {
            logger.error("Telemetry.plist missing or invalid - telemetry disabled")
        }

        audioController = PdAudioController()
        coreLocationController = CoreLocationController()
        coreLocationController?.locationManager.stopUpdatingLocation()
        
        // Override point for customization after application launch.

        let defaults = UserDefaults.standard
        
        if let dg = defaults.string(forKey: defaultsKeys.defaultGame) {
            defaultGame = dg
        }
        else {
            defaultGame = ""
        }
        
        if let simulatorIp = defaults.string(forKey: defaultsKeys.rwaCreatorIP) {
            rwaCreatorIP = simulatorIp
        }
        else {
            rwaCreatorIP = "192.168.178.53"
        }
        
        if let headtracker = defaults.string(forKey: defaultsKeys.headtrackerId) {
            headtrackerID = headtracker
        }
        else {
            headtrackerID = "rwaht00"
        }
        
        if let eleInv = defaults.string(forKey: defaultsKeys.inverseElevation) {
            if eleInv == "true" {
                inverseElevation = true;
            }
            else {
                inverseElevation = false;
            }
        }
        else {
            inverseElevation = true;
        }
        
        if let useTracker = defaults.string(forKey: defaultsKeys.useHeadtracker) {
            if useTracker == "true" {
                useHeadTracker = true;
            }
            else {
                useHeadTracker = false;
            }
        }
        else {
            useHeadTracker = true;
        }
        
        if let _calibrateOnStart = defaults.string(forKey: defaultsKeys.calibrateOnStart) {
            if _calibrateOnStart == "true" {
                calibrateOnStart = true;
            }
            else {
                calibrateOnStart = false;
            }
        }
        else {
            calibrateOnStart = false;
        }

        configureAudio(audioController!)

        deviceId = defaults.string(forKey: defaultsKeys.deviceId) ?? ""
        useRtkGps = defaults.string(forKey: defaultsKeys.gpsSource) == "rtk"

        hideCurrentSceneTab()
        hideControlDataTab()
        installControlTab()
        installDiagnosticsTab()
        installSettingsTab()
        applySystemTabIcons()
        return true
    }

    /// Configures the libpd audio session
    /// Note: PdAudioPropertyChanged is not a failure: it means the
    /// session ran with adjusted properties (sample rate, buffer size),
    /// typical for Bluetooth devices, only PdAudioError is fatal.
    ///
    /// Bluetooth:
    /// - Input stays enabled (patches use adc~), but only over A2DP:
    ///   allowBluetoothA2DP keeps Bluetooth output on stereo/48 kHz while
    ///   input comes from the built-in mic.
    /// - Never set allowBluetooth (HFP): it overrides A2DP and would drop
    ///   AirPods to mono 16/24 kHz, which RWA Player can't use.
    private func configureAudio(_ controller: PdAudioController) {
        let requestedRate = Int32(sampleRate * 1000)
        controller.allowBluetoothA2DP = true
        let status = controller.configurePlayback(withSampleRate: requestedRate,
                                                  inputChannels: 1,
                                                  outputChannels: 2,
                                                  inputEnabled: true).controlStatus
        let ticksStatus = controller.configureTicksPerBuffer(16).controlStatus

        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute.outputs
            .map { "\($0.portName) [\($0.portType)]" }
            .joined(separator: ", ")
        let inputRoute = session.currentRoute.inputs
            .map { "\($0.portName) [\($0.portType)]" }
            .joined(separator: ", ")
        let state = "requested \(requestedRate) Hz, session \(session.sampleRate) Hz, "
            + "out \(controller.outputChannels) ch (session \(session.outputNumberOfChannels)), "
            + "in \(controller.inputChannels) ch (session \(session.inputNumberOfChannels)), "
            + "ticks/buffer \(controller.ticksPerBuffer), "
            + "route: \(route.isEmpty ? "none" : route), "
            + "input: \(inputRoute.isEmpty ? "none" : inputRoute)"

        switch status {
        case .ok:
            logger.info("audioController configured: \(state)")
        case .propertyChanged:
            // libpd logs the specific adjustment via AU_LOG.
            logger.info("audioController configured with adjusted properties: \(state)")
        case .error:
            logger.error("audioController configuration FAILED: \(state)")
        }
        if ticksStatus != .ok {
            logger.error("configureTicksPerBuffer(16) returned \(ticksStatus.rawValue); effective \(controller.ticksPerBuffer)")
        }
    }

    /// Swaps the storyboard's placeholder tab icons for SF Symbols that match
    /// the style of the Diagnostics tab's "waveform.path.ecg" icon. Done in
    /// code so the storyboard stays untouched.
    private func applySystemTabIcons() {
        guard let tabBar = window?.rootViewController as? UITabBarController else { return }
        let symbolsByTitle = [
            "Games": "list.bullet",
            "Control": "headphones",
            "Map": "map",
            "Diagnostics": "waveform.path.ecg",
            "Settings": "gearshape"
        ]
        for controller in tabBar.viewControllers ?? [] {
            guard let title = controller.tabBarItem.title,
                  let symbolName = symbolsByTitle[title] else { continue }
            controller.tabBarItem.image = UIImage(systemName: symbolName)
        }
    }

    /// Hides the "Current Scene" tab from the tab bar. That view controller
    /// (SecondViewController) still owns the BLE central manager, motion
    /// updates, and the game loop start/stop logic, so it must stay
    /// instantiated and loaded even though its tab is no longer shown —
    /// only the tab bar entry is removed. loadViewIfNeeded() forces its
    /// viewDidLoad (BLE setup, notification observers) to run immediately
    /// instead of waiting for the tab to be selected, and the strong
    /// reference in currentSceneController keeps it alive after it leaves
    /// the tab bar (otherwise it would deallocate and its notification
    /// observers — "Start Game", "Connect Headtracker", … — would die with it).
    private func hideCurrentSceneTab() {
        guard let tabBar = window?.rootViewController as? UITabBarController,
              let controllers = tabBar.viewControllers,
              let currentSceneVC = controllers.first(where: { $0.tabBarItem.title == "Current Scene" }) else { return }
        currentSceneVC.loadViewIfNeeded()
        currentSceneController = currentSceneVC
        tabBar.viewControllers = controllers.filter { $0 !== currentSceneVC }
    }

    /// Drops the storyboard's "Control Data" tab. Its settings moved to the
    /// Settings tab, its read-only sensor dumps to Diagnostics, and its live
    /// operator actions (plus the OSC receiver) to ControlViewController,
    /// installed just below. Unlike hideCurrentSceneTab() nothing needs to be
    /// kept alive here: ControlDataViewController owned no services beyond
    /// the OSC delegate, which the new controller took over — so the object
    /// is simply dropped and its view is never loaded. The storyboard scene
    /// stays behind as unreachable legacy scaffolding (Main.storyboard is not
    /// edited).
    private func hideControlDataTab() {
        guard let tabBar = window?.rootViewController as? UITabBarController,
              let controllers = tabBar.viewControllers else { return }
        tabBar.viewControllers = controllers.filter { $0.tabBarItem.title != "Control Data" }
    }

    /// Installs the operator Control tab, in code, like Diagnostics and
    /// Settings. Inserted at index 1 - the slot the Control Data tab held -
    /// because FirstViewController jumps to selectedIndex 1 after loading a
    /// game and the operator expects the Start button there.
    private func installControlTab() {
        guard let tabBar = window?.rootViewController as? UITabBarController else { return }
        let control = ControlViewController()
        let nav = UINavigationController(rootViewController: control)
        nav.tabBarItem = UITabBarItem(title: "Control", image: nil, tag: 1)
        var controllers = tabBar.viewControllers ?? []
        controllers.insert(nav, at: min(1, controllers.count))
        tabBar.viewControllers = controllers
    }

    /// Appends the Diagnostics ("About") tab as a 5th tab on the storyboard's
    /// tab bar controller. Done in code so the storyboard stays untouched.
    private func installDiagnosticsTab() {
        guard let tabBar = window?.rootViewController as? UITabBarController else { return }
        let about = AboutViewController(style: .grouped)
        let nav = UINavigationController(rootViewController: about)
        nav.tabBarItem = UITabBarItem(title: "Diagnostics", image: nil, tag: 4)
        var controllers = tabBar.viewControllers ?? []
        controllers.append(nav)
        tabBar.viewControllers = controllers
    }

    /// Appends the Settings tab, same pattern as the Diagnostics tab.
    private func installSettingsTab() {
        guard let tabBar = window?.rootViewController as? UITabBarController else { return }
        let settings = SettingsViewController(style: .grouped)
        let nav = UINavigationController(rootViewController: settings)
        nav.tabBarItem = UITabBarItem(title: "Settings", image: nil, tag: 5)
        var controllers = tabBar.viewControllers ?? []
        controllers.append(nav)
        tabBar.viewControllers = controllers
    }

    func applicationWillResignActive(_ application: UIApplication) {
        
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the inactive state; here you can undo many of the changes made on entering the background.
    }
   
    func applicationDidBecomeActive(_ application: UIApplication) {
        // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
        
            //audioController?.configureTicksPerBuffer(512)
            audioController?.isActive = true
       }

    func applicationWillTerminate(_ application: UIApplication) {
        
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    }
}

//MARK: - CONVERT ENUM FOR SWIFT

extension PdAudioStatus {
    enum ControlStatus: String {
        case ok               // PdAudioOK: as requested
        case error            // PdAudioError: unrecoverable
        case propertyChanged  // PdAudioPropertyChanged: works, with adjusted properties
    }

    var controlStatus: ControlStatus {
        switch self.rawValue {
        case PdAudioOK.rawValue:
            return .ok
        case PdAudioError.rawValue:
            return .error
        default:
            return .propertyChanged
        }
    }
}

