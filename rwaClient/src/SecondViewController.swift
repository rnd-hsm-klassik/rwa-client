//
//  SecondViewController.swift
//  rwa client
//
//  Created by Admin on 28/12/15.
//  Copyright © 2015 beryllium design. All rights reserved.
//

import UIKit
import MapKit
import CoreMotion

// 10ms
let schedulerRate: Double = 10

// fade-times for start / stop (phase A)
let masterFadeOutMs = 800
let masterFadeInMs = 300
// one audio buffer (16 ticks * 64 samples at 48 kHz ~ 21 ms) plus margin for phase B
let stopTeardownDelayMs = masterFadeOutMs + 100
let stopSettleMs = 60

// True during phase A+B of a stop. isRunning stays true throughout, so every
// guard that protects a running game keeps holding; this flag separates
// "stopping" from "running" for the UI and for start-queueing.
var gameStopInProgress = false

var ubloxLon = Double("3.1415926536")
var ubloxLat = Double("3.1415926536")
// Freshness markers for telemetry source attribution (read at 1 Hz by
// AppTelemetrySampler): when did the headset assembly last send GPS / heading data.
// The CoreLocation counterparts (locationUpdatedAt, lastInternalLocation)
// live in CoreLocationController.swift next to their writer.
var ubloxUpdatedAt: Date?
var trackerHeadingUpdatedAt: Date?
var azimuth = 0
var elevation = 0
var step = 0;
var lastStep = -1;
var currentScene = ""
var currentState = ""
var azimuthOffset = 0
var elevationOffset = 0
var azimuthOrg = 0
var elevationOrg = 0
var pdGainVal:Float = 2.0
var stepThresh = 0.6
var useHeadTracker = true
var headTrackerConnected = false
// True while the central is scanning/connecting (BLE mode only) — drives
// the Control tab's "Connecting…" button state. Volatile, never persisted.
var headTrackerConnecting = false
var linAccel:Float = 0;
var linAccelAverage:Float = 0;
var linAccelMovingAverage =  [Float](repeating: 0.0, count: 100)
var linAccelAkkum:Float = 0;
var stepCount = -1;
var averageAccel:MovingAverage = MovingAverage(period: 128)
var calibrateOnStart = false

class SecondViewController: UIViewController
{
    @IBOutlet var startStopButton:UIButton!
    @IBOutlet var txtTask: UITextField!
    @IBOutlet var headTrackerData: UITextField!
    @IBOutlet var pdGainSlider: UISlider!
    @IBOutlet var register: UIButton!
    @IBOutlet var bleConnectButton: UIButton!
    @IBOutlet var showMovementDataButton: UIButton!
    @IBOutlet var lat: UITextField!
    @IBOutlet var currentScene: UITextField!
    @IBOutlet var currentState: UITextField!
    @IBOutlet var useNewHeadtracker:UIButton!
    @IBOutlet var calibrateOnStartSwitch:UISwitch!

    var timer:Timer? = Timer()
    var unblockStepTime:Timer? = Timer()
    var displayTimer:Timer? = Timer()
    var loadingGame:UIActivityIndicatorView = UIActivityIndicatorView()

    var motion:CMMotionManager = CMMotionManager();

    var showMovementData = false
    var linAccelAverageCounter = 0;
    var lastAverageCounter = 0;
    var lastAccelVal = 0;
    var queue: OperationQueue = OperationQueue();
    
    var motionErrorLogged = false

    func startQueuedUpdates() {
       if motion.isDeviceMotionAvailable {
          logger.info("Motion: starting device-motion updates (internal heading)")
          motionErrorLogged = false
          self.motion.deviceMotionUpdateInterval = 1.0 / 100.0
          self.motion.showsDeviceMovementDisplay = true
          self.motion.startDeviceMotionUpdates(using: .xTrueNorthZVertical, to: self.queue, withHandler: { (data, error) in
             // xTrueNorthZVertical needs the magnetometer and location; when
             // either is unavailable the handler fires with an error and no
             // data — without this log the internal heading dies silently.
             if let error = error, !self.motionErrorLogged {
                self.motionErrorLogged = true
                logger.error("Motion: device-motion error: \(error.localizedDescription)")
             }
             // Make sure the data is valid before accessing it.
             if let validData = data {
                // Get the attitude relative to the magnetic north reference frame.
                 let roll = validData.attitude.roll * (180/Double.pi);
                 let yaw = validData.attitude.yaw * (180/Double.pi);
                 
                 var azi = Int(yaw)
                 if azi <= 0 {
                     azi = -azi
                 }
                 else {
                     azi = 360 - azi
                 }
                 
                 var ele = -Int(roll)
                 if inverseElevation {
                    ele = Int(roll)
                 }
                 
                 hero.azimuth = azi
                 hero.elevation = ele
                 // The engine's non-headtracker-relative Pd path
                 // (RwaGameLoop.sendData2Asset) sends the raw azimuth/
                 // elevation globals, which only the BLE parser filled —
                 // internal heading never reached those receivers. Mirror
                 // the tracker path. (ele already has inverseElevation
                 // applied, matching the parser.)
                 azimuth = azi
                 elevation = ele
             }
          })
           headTrackerConnected = true
           updateButtons()
           NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Update Buttons"), object: nil)
       }
       else {
           logger.error("Motion: device motion unavailable - internal heading disabled")
       }
        
        if (motion.isAccelerometerAvailable) {
            motion.accelerometerUpdateInterval = 0.02;
            motion.startAccelerometerUpdates(to: self.queue, withHandler: { (data, error) in
                if let validData = data {
                    let z_acceleration = validData.acceleration.z
                    linAccelAverage = Float(averageAccel.average(value: Double(-z_acceleration)))
                    linAccel = Float(-z_acceleration)
                    StepDetector.shared.process();
                }
            });
        }
    }
    
    func stopDeviceOrientation()
    {
        if motion.isDeviceMotionAvailable {
            self.motion.stopDeviceMotionUpdates() }
    }
    
    func setInputGain(gain: Float) {
        let audioSession = AVAudioSession.sharedInstance()
        if audioSession.isInputGainSettable {
            do {
                try audioSession.setInputGain(gain)
                // do something with data
                // if the call fails, the catch block is executed
            } catch {
                logger.error("setInputGain failed: \(error.localizedDescription)")
            }
        }
    }

    // True while a start was requested during a stop's teardown; the queued
    // start fires from finishStop() once the reset completes. A stop request
    // arriving in the meantime cancels it (the stop wins).
    var startPending = false

    @objc func start()
    {
        // A start during teardown is queued, not lost:
        // finishStop() launches it once the reset is complete.
        if(gameStopInProgress) {
            startPending = true
            return
        }
        if(rwagameloop.isRunning) {
            return
        }

        // Start silent: the master [line~] in stereoout.pd jumps to 0, so
        // nothing left standing in the signal graph is heard, then ramps to
        // 1.0 below. (Belt and braces: a completed stop leaves it at 0.)
        rwagameloop.sendMasterFade(0, 0)

        let interval:TimeInterval = schedulerRate/1000
        rwagameloop.isRunning = true
        rwagameloop.startGame()
        TelemetryService.shared?.recordAppEvent(name: "walk_started", data: ["soundwalk": currentGame])
        // Use the global pdGainVal (kept up to date by the Control tab's
        // volume slider) instead of this hidden tab's own slider, which is
        // stuck at its storyboard default and would clobber the user's volume.
        PdBase.send(Float(pdGainVal), toReceiver: "rwamainvolume")
        rwagameloop.sendMasterFade(1.0, masterFadeInMs)
        timer = Timer.scheduledTimer(timeInterval: interval, target: self, selector: #selector(SecondViewController.countUp), userInfo: nil, repeats: true)
        NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Update Buttons"), object: nil)
        NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Redraw Map"), object: nil)

        if(headTrackerConnected && calibrateOnStart)  // this is here because something weird happend in zofingen, north was sometimes not north anymore..:(
        {
            azimuthOffset = azimuthOrg
            elevationOffset = elevationOrg
        }
    }

    /// Phase A of the two-phase stop: no new asset activity (loop timer off),
    /// audible fade of the master output to 0 while the stream keeps running.
    /// isRunning stays true until phase B completes, so every guard that
    /// protects a running game keeps holding.
    @objc func stop()
    {
        if(gameStopInProgress) {
            // Stop while a queued start waits: the stop wins, the start is forgotten.
            startPending = false
            return
        }
        if(!rwagameloop.isRunning) {
            return
        }

        gameStopInProgress = true
        timer?.invalidate()
        TelemetryService.shared?.recordAppEvent(name: "walk_stopped")
        currentScene.text = "Current Scene"
        currentState.text = "Current State"
        // Audible fade-outs of the assets themselves; whatever outlasts the
        // master fade is cut silently in phase B.
        rwagameloop.sendEnd2BackgroundAssets()
        rwagameloop.sendEnd2ActiveAssets()
        rwagameloop.sendMasterFade(0, masterFadeOutMs)
        NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Update Buttons"), object: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(stopTeardownDelayMs), execute: {
            self.finishStop()
        })
    }

    /// Phase B1, after the fade has conmpleted: the whole patcher pool
    /// completes its release protocol. Unlike the Creator, the Player never
    /// closes the audio stream, so the zero-length fades queued here mature
    /// in real time on the live (silent, master fade is at 0) stream.
    /// Phase B2 follows after the settle window instead of a hand-flushed
    /// scheduler. Safe without the Creator's close-stream step because this
    /// libpd serializes every API call and the render callback with sys_lock.
    func finishStop()
    {
        if(!rwagameloop.isRunning) {
            // A synchronous stop already ran; the scheduled phase B no-ops.
            gameStopInProgress = false
            return
        }

        rwagameloop.resetAllPatchers()

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(stopSettleMs), execute: {
            self.completeStop()
        })
    }

    /// Phase B2, once every pending clock has matured: drain the receive
    /// queue *now* (never on a delayed timer - a delayed drain leaks this
    /// run's "-playfinished" bangs into the next run), clear the asset maps,
    /// and only then allow (or fire the queued) start. Bangs the 20 ms poll
    /// timer picked up during the settle window went through receiveBang
    /// with the maps intact (the normal release path), the drain catches
    /// the rest.
    func completeStop()
    {
        if(!rwagameloop.isRunning) {
            // A synchronous stop already ran; the scheduled phase B2 no-ops.
            gameStopInProgress = false
            return
        }

        PdBase.receiveMessages()
        // leftovers: dynamic patches without the protocol never send playfinished.
        hero.activeAssets.removeAll()
        hero.backgroundAssets.removeAll()

        rwagameloop.isRunning = false
        gameStopInProgress = false
        NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Update Buttons"), object: nil)
        NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Game Stopped"), object: nil)

        if(startPending) {
            startPending = false
            start()
        }
    }

    /// Synchronous stop variant for app termination: no fade, no settle,
    /// scheduled timers never fire once the run loop winds down, and Pd's
    /// state dies with the process, so un-matured clocks are moot; the reset
    /// and drain just keep the app-side state consistent.
    func stopGameNow()
    {
        if(!rwagameloop.isRunning) {
            return
        }
        timer?.invalidate()
        startPending = false
        if(!gameStopInProgress) {
            TelemetryService.shared?.recordAppEvent(name: "walk_stopped")
        }
        gameStopInProgress = true
        rwagameloop.resetAllPatchers()
        completeStop()
    }

    @objc func countUp()
    {
        rwagameloop.updateGameState()
        
        if(showMovementData) {
            lat.text = "\(hero.coordinates.longitude) \(hero.coordinates.latitude)"
        }
        if(sceneChanged) {
            currentScene.text = hero.currentScene?.name
            sceneChanged = false
        }
        if(stateChanged) {
            currentState.text = hero.currentState?.stateName
            stateChanged = false
        }
    }
    
    @objc func gameLoaded()
    {
        loadingGame.stopAnimating()
        connectHeadtracker()
        TelemetryService.shared?.setSoundwalkId(currentGame)
    }
    
    func initGui()
    {
        txtTask.isUserInteractionEnabled = false
        headTrackerData.isUserInteractionEnabled = false
        currentScene.isUserInteractionEnabled = false
        currentState.isUserInteractionEnabled = false
    }
    
    override func viewDidLoad()
    {
        NotificationCenter.default.addObserver(self, selector: #selector(self.gameLoaded), name: NSNotification.Name(rawValue: "Game Loaded"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.connectHeadtracker), name: NSNotification.Name(rawValue: "Connect Headtracker"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.start), name: NSNotification.Name(rawValue: "Start Game"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.stop), name: NSNotification.Name(rawValue: "Stop Game"), object: nil)

        initGui()
        pdGainSlider.value = 0.5;
        
        self.navigationItem.hidesBackButton = true
        loadingGame.center = self.view.center;
        loadingGame.hidesWhenStopped = true;
        loadingGame.activityIndicatorViewStyle = UIActivityIndicatorViewStyle.whiteLarge
        view.addSubview(loadingGame)
        loadingGame.startAnimating()
        super.viewDidLoad()
    }

    override func didReceiveMemoryWarning()
    {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    @objc func updateDisplay() {
        DispatchQueue.main.async() {
            self.headTrackerData.text = String("\(hero.azimuth)  \(hero.elevation) \(stepCount)")
        }
    }
    
    func updateConnectBleButton()
    {
        DispatchQueue.main.async() {
            if(headTrackerConnected) {
                if(useHeadTracker) {
                    self.bleConnectButton.setTitle("Headtracker connected", for: UIControlState()) }
                else {
                    self.bleConnectButton.setTitle("Using Device Orientation", for: UIControlState()) }
            }
            else {
                self.bleConnectButton.setTitle("Connect Headtracker", for: UIControlState())
            }
        }
    }
    
    func updateStartStopButton()
    {
        DispatchQueue.main.async() {
            if(gameStopInProgress) {
                self.startStopButton.setTitle("Stopping…", for: UIControlState())
            }
            else if(rwagameloop.isRunning) {
                self.startStopButton.setTitle("Stop", for: UIControlState())
            }
            else {
                self.startStopButton.setTitle("Start", for: UIControlState())
            }
        }
    }
    
    func updateGameLabel()
    {
        DispatchQueue.main.async() {
            self.txtTask.text = currentGame
        }
    }
    
    func updateButtons()
    {
        updateStartStopButton()
        updateConnectBleButton()
        updateGameLabel()
    }
    
    @IBAction func updateCalibrateOnStartSwitch(_ sender: UISwitch)
    {
        let defaults = UserDefaults.standard
        calibrateOnStart = sender.isOn
        if(sender.isOn) {
            defaults.set("true", forKey: defaultsKeys.calibrateOnStart)
        }
        else {
            defaults.set("false", forKey: defaultsKeys.calibrateOnStart)
        }
    }
    
    override func viewWillAppear(_ animated: Bool)
    {
        txtTask.text = currentGame
        displayTimer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(updateDisplay), userInfo: nil, repeats: true)
        
        updateButtons()
        
        if(calibrateOnStart) {
            calibrateOnStartSwitch.isOn = true
        }
        else {
            calibrateOnStartSwitch.isOn = false
        }
     }
    
    override func viewWillDisappear(_ animated: Bool)
    {
        displayTimer?.invalidate();
    }
    
    @objc func connectHeadtracker() {
        // Heading axis only: the BLE central lives in HeadtrackerManager,
        // which observes the same "Connect Headtracker" / "Game Loaded"
        // notifications for its side.
        updateButtons()
        if(useHeadTracker) {
            stopDeviceOrientation()
        }
        else {
            startQueuedUpdates();
        }
    }

    @IBAction func bleConnect(_ sender: UIButton)
    {
        // Legacy hidden-tab button: reaches both this controller (heading
        // axis) and HeadtrackerManager (BLE axis) via the notification.
        NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Connect Headtracker"), object: nil)
        logger.info("BT: assembly target: \(assemblyTargetName())")
        updateConnectBleButton()
    }
    
    @IBAction func pdGain(_ sender: UISlider)
    {
        //print(pdGainSlider.value)
        pdGainVal = pdGainSlider.value * 5.0
        PdBase.send(Float(pdGainVal), toReceiver: "rwamainvolume")
        logger.info("pdGainVal: \(pdGainVal)")
    }

    @IBAction func startStop(_ sender: UIButton)
    {
        if(!rwagameloop.isRunning)
        {
            start()
        }
        else
        {            
            stop()
        }
        updateStartStopButton()
        
    }
}

