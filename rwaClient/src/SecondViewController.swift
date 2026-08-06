//
//  SecondViewController.swift
//  rwa client
//
//  Created by Admin on 28/12/15.
//  Copyright © 2015 beryllium design. All rights reserved.
//

import UIKit
import CoreBluetooth
import MapKit
import CoreMotion

// 10ms
let schedulerRate: Double = 10

var ubloxLon = Double("3.1415926536")
var ubloxLat = Double("3.1415926536")
// Freshness markers for telemetry source attribution (read at 1 Hz by
// LiveTelemetrySource): when did the tracker last send GPS / heading data.
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

class SecondViewController: UIViewController, CBCentralManagerDelegate, CBPeripheralDelegate
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
    var rssiTimer:Timer?
    var loadingGame:UIActivityIndicatorView = UIActivityIndicatorView()
 
    var centralManager:CBCentralManager!
    var peripheral:CBPeripheral?
    var dataBuffer:NSMutableData!
    var scanAfterDisconnecting:Bool = true
    var motion:CMMotionManager = CMMotionManager();
    
    var showMovementData = false
    var linAccelAverageCounter = 0;
    var lastAverageCounter = 0;
    var lastAccelVal = 0;
    var blockSteps = false;
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
                    self.evalAccelData();
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
    
    func stopScanning() {
        if(centralManager != nil) {
            centralManager.stopScan()
        }
    }
    
    func startScanning() {
        if centralManager.isScanning {
            logger.info("BT: Central Manager is already scanning.")
            return;
        }
        
        if(!useHeadTracker) {
            logger.info("BT: App is set to use device orientation.")
            return;
        }
        else {
            centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey:true])
            logger.info("BT: Scanning Started.")
            headTrackerConnecting = true
            NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Update Buttons"), object: nil)
        }
    }
    
    func disconnect() {
        guard let peripheral = self.peripheral else {
            logger.warning("BT: Peripheral object has not been created yet.")
            return
        }
        
        if peripheral.state != .connected {
            logger.warning("BT: Peripheral exists but is not connected.")
            self.peripheral = nil
            return
        }
        
        guard let services = peripheral.services else {
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        
        for service in services {
            if let characteristics = service.characteristics {
                for characteristic in characteristics {
                    if characteristic.uuid == CBUUID.init(string: Device.TransferCharacteristic) {
                        // We can return after calling CBPeripheral.setNotifyValue because CBPeripheralDelegate's
                        // didUpdateNotificationStateForCharacteristic method will be called automatically
                        peripheral.setNotifyValue(false, for: characteristic)
                        return
                    }
                }
            }
        }
        
        // We have a connection to the device but we are not subscribed to the Transfer Characteristic for some reason.
        // Therefore, we will just disconnect from the peripheral
        centralManager.cancelPeripheralConnection(peripheral)
    }
    
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        if let peripheralsObject = dict[CBCentralManagerRestoredStatePeripheralsKey] {
            let peripherals = peripheralsObject as! Array<CBPeripheral>
            if peripherals.count > 0 {
                // Just grab the first one in this case. If we had maintained an array of
                // multiple peripherals then we would just add them to our array and set the delegate...
                peripheral = peripherals[0]
                peripheral?.delegate = self
            }
        }
    }
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logger.info("BT: Central Manager State Updated: \(String(describing: central.state))")
        
        // We showed more detailed handling of this in Zero-to-BLE Part 2, so please refer to that if you would like more information.
        // We will just handle it the easy way here: if Bluetooth is on, proceed...
        if central.state != .poweredOn {
            self.peripheral = nil
            headTrackerConnecting = false
            NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Update Buttons"), object: nil)
            return
        }
        
        startScanning()
        
        //--------------------------------------------------------------
        // If the app has been restored with the peripheral in centralManager(_:, willRestoreState:),
        // we start subscribing to updates again to the Transfer Characteristic.
        //--------------------------------------------------------------
        // check for a peripheral object
        guard let peripheral = self.peripheral else {
            return
        }
        
        // see if that peripheral is connected
        guard peripheral.state == .connected else {
            return
        }
        
        // make sure the peripheral has services
        guard let peripheralServices = peripheral.services else {
            return
        }
        
        // we have services, but we need to check for the Transfer Service
        // (honestly, this may be overkill for our project but it demonstrates how to make this process more bulletproof...)
        // Also: Pardon the pyramid.
        let serviceUUID = CBUUID(string: Device.TransferService)
        if let serviceIndex = peripheralServices.index(where: {$0.uuid == serviceUUID}) {
            // we have the service, but now we check to see if we have a characteristic that we've subscribed to...
            let transferService = peripheralServices[serviceIndex]
            let characteristicUUID = CBUUID(string: Device.TransferCharacteristic)
            if let characteristics = transferService.characteristics {
                if let characteristicIndex = characteristics.index(where: {$0.uuid == characteristicUUID}) {
                    // Because this is a characteristic that we subscribe to in the standard workflow,
                    // we need to check if we are currently subscribed, and if not, then call the
                    // setNotifyValue like we did before.
                    let characteristic = characteristics[characteristicIndex]
                    if !characteristic.isNotifying {
                        peripheral.setNotifyValue(true, for: characteristic)
                    }
                } else {
                    // if we have not discovered the characteristic yet, then call discoverCharacteristics, and the delegate method will get called as in the standard workflow...
                    peripheral.discoverCharacteristics([characteristicUUID], for: transferService)
                }
            }
        } else {
            // we have a CBPeripheral object, but we have not discovered the services yet,
            // so we call discoverServices and the delegate method will handle the rest...
            peripheral.discoverServices([serviceUUID])
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        logger.debug("BT: Discovered \(String(describing: peripheral.name)) at \(RSSI)")
        if(peripheral.name == headtrackerID)
        {
            if self.peripheral != peripheral {
                
                // save a reference to the peripheral object so Core Bluetooth doesn't get rid of it
                self.peripheral = peripheral
                
                // connect to the peripheral
                logger.info("BT: Connecting to peripheral: \(peripheral)")
                centralManager?.connect(peripheral, options: nil)
            }
        }
    }

    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logger.info("BT: Peripheral Connected!!!")
        
        centralManager.stopScan()
        logger.info("BT: Scanning Stopped!")
        bleConnectButton.setTitle("BLE Connected", for: UIControlState())
        bleConnectButton.isEnabled = false
        headTrackerConnected = true
        headTrackerConnecting = false
        DeviceHealth.shared.setBLEConnected(true)
        rssiTimer?.invalidate()
        rssiTimer = Timer.scheduledTimer(timeInterval: 2.0, target: self,
                                         selector: #selector(pollRSSI),
                                         userInfo: nil, repeats: true)
        NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Headtracker Connected"), object: nil)
        // Let the Control Data tab (which now hosts the Connect button) refresh its title
        NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Update Buttons"), object: nil)
        dataBuffer.length = 0
        
        // IMPORTANT: Set the delegate property, otherwise we won't receive the discovery callbacks, like peripheral(_:didDiscoverServices)
        peripheral.delegate = self
       
        logger.info("BT: Looking for Transfer Service...")  // This time, we will search for the transfer service UUID
        peripheral.discoverServices(nil)
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logger.info("BT: Failed to connect to \(peripheral) (\(String(describing: error?.localizedDescription)))")
      //  connectionIndicatorView.layer.backgroundColor = UIColor.red.cgColor
        self.disconnect()
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logger.info("BT: Disconnected from Peripheral")
        self.peripheral = nil
        // A partially received telemetry frame must not be glued to bytes
        // from the next connection (the device also restarts its stream).
        DeviceTelemetryReceiver.shared.connectionReset()
        rssiTimer?.invalidate()
        rssiTimer = nil
        DeviceHealth.shared.setBLEConnected(false)
        bleConnectButton.setTitle("BLE Connect", for: UIControlState())
        headTrackerConnected = false
        bleConnectButton.isEnabled = true
        hero.disconnectedFromHeadtrackerSince = 0.0;
        NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Update Buttons"), object: nil)
        
        if scanAfterDisconnecting {
            startScanning()
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        
        logger.info("BT: Discovered Services!!!")
        
        if error != nil {
            logger.error("BT: Error discovering services: \(String(describing: error?.localizedDescription))")
            disconnect()
            return
        }
        
        if let services = peripheral.services {
            
            for service in services {
                logger.info("BT: Discovered service \(service)")
                
                // If we found either the transfer service, discover the transfer characteristic
                // plus the raw RTK position characteristic (713D0004) — the firmware sends
                // high-precision position there, not as "l" frames on the headtracker char.
                if (service.uuid == CBUUID(string: Device.TransferService)) {
                    peripheral.discoverCharacteristics([
                        CBUUID(string: Device.TransferCharacteristic),
                        CBUUID(string: Device.TRACKERRAWDATA)
                    ], for: service)
                }

                // Telemetry service (PROJECT-PLAN.md §5.1): CBOR event feed
                if (service.uuid == CBUUID(string: Device.TelemetryService)) {
                    let telemetryTxUUID = CBUUID(string: Device.TelemetryTxCharacteristic)
                    peripheral.discoverCharacteristics([telemetryTxUUID], for: service)
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if error != nil {
            logger.error("BT: Error discovering characteristics: \(String(describing: error?.localizedDescription))")
            return
        }
        
        if let characteristics = service.characteristics {
            for characteristic in characteristics {
                
                if characteristic.uuid == CBUUID(string: Device.TransferCharacteristic) {
                    // subscribe to dynamic changes
                    logger.info("BT: Found RWA Headtracker")
                    peripheral.setNotifyValue(true, for: characteristic)
                }

                if characteristic.uuid == CBUUID(string: Device.TRACKERRAWDATA) {
                    logger.info("BT: Found RTK raw position, subscribing")
                    peripheral.setNotifyValue(true, for: characteristic)
                }

                if characteristic.uuid == CBUUID(string: Device.TelemetryTxCharacteristic) {
                    logger.info("BT: Found telemetry TX, subscribing")
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        }
    }
    
    @objc func pollRSSI() {
        peripheral?.readRSSI()
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if error == nil {
            DeviceHealth.shared.setRSSI(RSSI.intValue)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?)
    {
        if error != nil {
            logger.error("BT: Error updating value for characteristic: \(characteristic) - \(String(describing: error?.localizedDescription))")
            return
        }
        
        // make sure we have a characteristic value
        guard let value = characteristic.value else {
            logger.info("BT: Characteristic Value is nil on this go-round")
            return
        }

        // Telemetry frames are binary CBOR (PROJECT-PLAN.md §5) — handle
        // them before the UTF-8 text decode below.
        if characteristic.uuid == CBUUID(string: Device.TelemetryTxCharacteristic) {
            DeviceTelemetryReceiver.shared.ingest(value)
            return
        }

        // Raw RTK position (713D0004, up to 10 Hz): the feed RTK positioning
        // runs on. Freshness of ubloxUpdatedAt is what keeps CoreLocation in
        // standby (CoreLocationController) and tags the source "(RTK)".
        if characteristic.uuid == CBUUID(string: Device.TRACKERRAWDATA) {
            guard let text = String(data: value, encoding: .utf8),
                  let position = Device.parseRawTrackerPosition(text) else {
                logger.debug("BT: malformed raw RTK position frame")
                return
            }
            ubloxLat = position.lat
            ubloxLon = position.lon
            ubloxUpdatedAt = Date()

            // RTK positioning (Settings tab): tracker coordinates drive
            // the walk. OSC-registered mode still overrides everything.
            if(useRtkGps && !registered) {
                hero.coordinates = CLLocationCoordinate2D(latitude: position.lat,
                                                          longitude: position.lon)
                hero.timeSinceLastGpsUpdate = 0.0
            }
            return
        }

        // make sure we have a characteristic value
        guard let nextChunk = String(data: value, encoding: String.Encoding.utf8) else {
            logger.debug("BT: Next chunk of data is nil.")
            return
        }
        
        let words = nextChunk.components(separatedBy: " ")
        if characteristic.uuid == CBUUID(string: Device.TRACKERSERVICETX)
        {
            if words.count < 3 {
                return;
            }
            
            else if words[0] == "l"
            {
               // ubloxLon = Int(NSString(string:words[1].digits).intValue) * (1/10000000);
               // ubloxLat = Int(NSString(string:words[2].digits).intValue) * (1/10000000);
                ubloxLat = Double(words[1])! * (1/10000000)
                ubloxLon = Double(words[2])! * (1/10000000)
                ubloxUpdatedAt = Date()

                // RTK positioning (Settings tab): tracker coordinates drive
                // the walk. OSC-registered mode still overrides everything.
                if(useRtkGps && !registered) {
                    hero.coordinates = CLLocationCoordinate2D(latitude: ubloxLat!, longitude: ubloxLon!)
                    hero.timeSinceLastGpsUpdate = 0.0
                }
               // print(print("lon lat: \(ubloxLon) \(ubloxLat)"))
               // print(print("lon lat: \(hero.coordinates.longitude) \(hero.coordinates.latitude)"))
                //london.coordinate = CLLocationCoordinate2D(latitude: ubloxLat!, longitude: ubloxLon!)
                
            }
            // Heading frames only count while the headtracker is the heading
            // source: with Internal selected a tracker connected for RTK
            // positioning would otherwise overwrite the CoreMotion heading
            // (and double-count steps) on every frame.
            else if(useHeadTracker)
            {
                var azimuthTmp = words[0]
                let elevationTmp = words[1]
                let linAccTmp = words[2]

                azimuthTmp = azimuthTmp.digits
                
                azimuthOrg = Int(NSString(string: azimuthTmp).intValue)
                azimuth = azimuthOrg-azimuthOffset
                if(azimuth < 0) {
                        azimuth += 360 }
                
                elevationOrg = Int(NSString(string: elevationTmp).intValue)
                elevation = elevationOrg-elevationOffset
                
                if(inverseElevation) {
                    elevation = -elevation;
                }
                
                linAccel = NSString(string: linAccTmp).floatValue

                linAccelAverage = Float(averageAccel.average(value: Double(linAccel)))
                evalAccelData();
                
                hero.azimuth = azimuth
                hero.elevation = elevation
                hero.stepCount = stepCount
                trackerHeadingUpdatedAt = Date()
            }
        }
        else {
            logger.debug("BT: \(characteristic.uuid)");
        }
        
        // If we get the EOM tag, we fill the text view
        if (nextChunk == Device.EOM) {
            if let message = String(data: dataBuffer as Data, encoding: String.Encoding.utf8) {
               // textView.text = message
                logger.debug("BT: Final message: \(message)")
                
                // truncate our buffer now that we received the EOM signal!
                dataBuffer.length = 0
            }
        }
    }
    
    /*
     Invoked when the peripheral receives a request to start or stop providing notifications
     for a specified characteristic’s value.
     
     This method is invoked when your app calls the setNotifyValue:forCharacteristic: method.
     If successful, the error parameter is nil.
     If unsuccessful, the error parameter returns the cause of the failure.
     */
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        // if there was an error then print it and bail out
        if error != nil {
            logger.error("BT: Error changing notification state: \(String(describing: error?.localizedDescription))")
            return
        }
        
        if characteristic.isNotifying {
            // notification started
            logger.info("BT: Notification STARTED on characteristic: \(characteristic)")
        } else {
            // notification stopped
            logger.error("BT: Notification STOPPED on characteristic: \(characteristic)")
            self.centralManager.cancelPeripheralConnection(peripheral)
        }
    }
    
    @objc func unblockSteps()
    {
        blockSteps = false;
        logger.info("Steps: unblock")
    }
    

    
    func evalAccelData()
    {
        //print(linAccelAverage);
        //print("Notification STARTED on characteristic: \(linAccelAverage) \(linAccel)")
        
        if(!blockSteps)
        {
            if(linAccel >= 0)
            {
                if(linAccelAverage >= 0)
                {
                    let dif = linAccel-linAccelAverage;
                    if(dif > 0.6)
                    {
                        step = 1;
                        stepCount+=1;
//                        unblockStepTime = Timer.scheduledTimer(timeInterval: 0.45, target: self, selector: #selector(SecondViewController.unblockSteps), userInfo: nil, repeats: false)
                        
                        // 450ms debounce
                        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(450), execute: {
                            self.unblockSteps()
                        })
                        
                        blockSteps = true;
                        logger.info("Steps: STEP_1");
                    }
                }
                else
                {
                    let dif = linAccel+linAccelAverage;
                    if(dif > 0.6)
                    {
                        stepCount+=1;
                        step = 1;
//                        unblockStepTime = Timer.scheduledTimer(timeInterval: 0.45, target: self, selector: #selector(SecondViewController.unblockSteps), userInfo: nil, repeats: false)
                        
                        // 450ms debounce
                        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(450), execute: {
                            self.unblockSteps()
                        })
                        blockSteps = true;
                        logger.info("Steps: STEP_2");
                    }
                }
            }
        }
    }
    
    @objc func start()
    {
        let interval:TimeInterval = schedulerRate/1000
        rwagameloop.isRunning = true
        rwagameloop.startGame()
        TelemetryService.shared?.recordAppEvent(name: "walk_started", data: ["soundwalk": currentGame])
        // Use the global pdGainVal (kept up to date by the Control tab's
        // volume slider) instead of this hidden tab's own slider, which is
        // stuck at its storyboard default and would clobber the user's volume.
        PdBase.send(Float(pdGainVal), toReceiver: "rwamainvolume")
        timer = Timer.scheduledTimer(timeInterval: interval, target: self, selector: #selector(SecondViewController.countUp), userInfo: nil, repeats: true)
        NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Update Buttons"), object: nil)
        NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Redraw Map"), object: nil)
        
        if(headTrackerConnected && calibrateOnStart)  // this is here because something weird happend in zofingen, north was sometimes not north anymore..:(
        {
            azimuthOffset = azimuthOrg
            elevationOffset = elevationOrg
        }
    }
    
    @objc func stop()
    {
        rwagameloop.isRunning = false
        TelemetryService.shared?.recordAppEvent(name: "walk_stopped")
        timer?.invalidate()
        currentScene.text = "Current Scene"
        currentState.text = "Current State"
        rwagameloop.sendEnd2BackgroundAssets()
        rwagameloop.sendEnd2ActiveAssets()
        NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Update Buttons"), object: nil)
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

        // Must happen here, not (only) in viewWillAppear: this controller stays
        // hidden (no tab) so viewWillAppear never runs, and a nil dataBuffer
        // would crash the first BLE didConnect callback.
        dataBuffer = NSMutableData()

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
            if(rwagameloop.isRunning) {
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
        dataBuffer = NSMutableData()
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
        headTrackerConnected = false
        updateButtons()
        if(useHeadTracker) {
            stopDeviceOrientation()
            centralManager = CBCentralManager(delegate: self, queue: nil)
        }
        else {
            headTrackerConnecting = false
            disconnect()
            startQueuedUpdates();
        }
    }
    
    @IBAction func bleConnect(_ sender: UIButton)
    {
        if(!headTrackerConnected) {
            connectHeadtracker()
            logger.info("BT: Headtracker ID: \(headtrackerID)")
        }
        else
        {
            disconnect()
        }
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

