//
//  AppDelegate.swift
//  rwa client
//
//  Created by Admin on 28/12/15.
//  Copyright © 2015 beryllium design. All rights reserved.
//

import UIKit

var coreLocationController:CoreLocationController?
var registered = false;
var headtrackerID = ""
var rwaCreatorIP = ""
var inverseElevation = true;
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
}

@UIApplicationMain

class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    var audioController:PdAudioController?
    var syntheticTelemetry: SyntheticTelemetrySource?
    var currentSceneController: UIViewController?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplicationLaunchOptionsKey: Any]?) -> Bool
    {
        if let telemetryConfig = TelemetryConfig.loadFromBundle() {
            let telemetry = TelemetryService(config: telemetryConfig)
            TelemetryService.shared = telemetry
            telemetry.start()
            telemetry.recordAppEvent(name: "app_launched")
            if telemetryConfig.syntheticSourceEnabled {
                let synthetic = SyntheticTelemetrySource(service: telemetry)
                synthetic.start()
                syntheticTelemetry = synthetic
            }
        }
        else {
            print("Telemetry.plist missing or invalid - telemetry disabled")
        }

        // Override point for customization after application launch.
        audioController = PdAudioController()
        coreLocationController = CoreLocationController()
        coreLocationController?.locationManager.stopUpdatingLocation()
        
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
       
        if let c = audioController
        {
            let sr = sampleRate * 1000
            let s = c.configurePlayback(withSampleRate: Int32(sr), inputChannels: 1, outputChannels: 2, inputEnabled: true).toPdAudioControlStatus()
            c.configureTicksPerBuffer(16)
            switch s{
            case .OK:
                print("succes");
            default:
                print("no succes");
            }
        }
        else
        {
            print("Could not init audiocontroller")
        }

        hideCurrentSceneTab()
        installDiagnosticsTab()
        applySystemTabIcons()
        return true
    }

    /// Swaps the storyboard's placeholder tab icons for SF Symbols that match
    /// the style of the Diagnostics tab's "waveform.path.ecg" icon. Done in
    /// code so the storyboard stays untouched.
    private func applySystemTabIcons() {
        guard let tabBar = window?.rootViewController as? UITabBarController else { return }
        let symbolsByTitle = [
            "Games": "list.bullet",
            "Control Data": "headphones",
            "Map": "map",
            "Diagnostics": "waveform.path.ecg"
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
    enum PdAudioControlStatus {
        case OK
        case Error
        case PropertyChanged
    }
    func toPdAudioControlStatus() -> PdAudioControlStatus {
        switch self.rawValue {
        case 0: //
            return .OK
        case -1: //
            return .Error
        default: //
            return .PropertyChanged
        }
    }
}

