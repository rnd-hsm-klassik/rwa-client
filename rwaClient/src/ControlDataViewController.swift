//
//  ControlDataViewController.swift
//  rwaclient
//
//  Created by Admin on 09.10.18.
//  Copyright © 2018 beryllium design. All rights reserved.
//

import UIKit

class ControlDataViewController: UIViewController, UITextFieldDelegate, F53OSCPacketDestination {
    
    var timer:Timer? = Timer()
  
    @IBOutlet var motherIp: UITextField!
    @IBOutlet var register: UIButton!
    @IBOutlet var startStopButton: UIButton!
    @IBOutlet var headTrackerData: UITextField!
    @IBOutlet var headtrackerId: UITextField!
    @IBOutlet var coordinates: UITextField!
    @IBOutlet var currentScene: UITextField!
    @IBOutlet var currentState: UITextField!
    @IBOutlet var useDeviceOrientation:UISwitch!
    @IBOutlet var inverseElevationSwitch:UISwitch!
    @IBOutlet var sendGPS2CreatorSwitch:UISwitch!
    @IBOutlet var bleConnectButton: UIButton!
    @IBOutlet var pdGainSlider: UISlider!
    @IBOutlet var calibrateOnStartSwitch: UISwitch!

    func initGui()
    {
        headTrackerData.isUserInteractionEnabled = false
        coordinates.isUserInteractionEnabled = false
        currentScene.isUserInteractionEnabled = false
        currentState.isUserInteractionEnabled = false
    }
    
    override func viewDidLoad()
    {
        super.viewDidLoad()
        initGui();
        motherIp.delegate = self
        headtrackerId.delegate = self
        motherIp.text = rwaCreatorIP
        headtrackerId.text = headtrackerID
        pdGainSlider.value = 0.5
        updateButtons()
        NotificationCenter.default.addObserver(self, selector: #selector(self.updateButtons), name: NSNotification.Name(rawValue: "Update Buttons"), object: nil)
    }
    
    override func viewWillAppear(_ animated: Bool)
    {
        oscServer.port = 8000
        oscServer.delegate = self       
        oscClient.port = 8000
        timer = Timer.scheduledTimer(timeInterval: 0.25, target: self, selector: #selector(update), userInfo: nil, repeats: true)
        if(registered) {
            startListening()
        }
        
        updateButtons()
        motherIp.text = rwaCreatorIP
        calibrateOnStartSwitch.isOn = calibrateOnStart
    }
    
    override func viewWillDisappear(_ animated: Bool)
    {
        timer?.invalidate();
        if(registered) {
            oscServer.stopListening(); }
    }
    
    func textFieldShouldReturn(_ textField: UITextField) -> Bool
    {
        textField.resignFirstResponder();
        let defaults = UserDefaults.standard
        rwaCreatorIP = motherIp.text!
        headtrackerID = headtrackerId.text!
        defaults.set(motherIp.text, forKey: defaultsKeys.rwaCreatorIP)
        defaults.set(headtrackerId.text, forKey: defaultsKeys.headtrackerId)
        return true;
    }
    
    func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool
    {
        return true
    }
    
    @objc func update()
    {
        DispatchQueue.main.async() {
            self.headTrackerData.text = String("\(hero.azimuth)   \(hero.elevation)   \(hero.stepCount)")
            self.coordinates.text = String("\(hero.coordinates.longitude)  \(hero.coordinates.latitude)")
            self.currentScene.text = hero.currentScene?.name
            self.currentState.text = hero.currentState?.stateName
        }
    }
    
    func getWiFiAddress() -> String?
    {
        var address : String?
        
        // Get list of all interfaces on the local machine:
        var ifaddr : UnsafeMutablePointer<ifaddrs>? = nil
        if getifaddrs(&ifaddr) == 0 {
            
            // For each interface ...
            var ptr = ifaddr
            while ptr != nil
            {
                let interface = ptr?.pointee
                
                // Check for IPv4 or IPv6 interface:
                let addrFamily = interface?.ifa_addr.pointee.sa_family
               // if addrFamily == UInt8(AF_INET) || addrFamily == UInt8(AF_INET6)
                if addrFamily == UInt8(AF_INET) {
                    
                    // Check interface name:
                    
                    let name = String(cString: (interface?.ifa_name)!)
                    if name == "en0"
                    {
                        // Convert interface address to a human readable string:
                        var addr = interface?.ifa_addr.pointee
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(&addr!, socklen_t((interface?.ifa_addr.pointee.sa_len)!),
                                    &hostname, socklen_t(hostname.count),
                                    nil, socklen_t(0), NI_NUMERICHOST)
                        address = String(cString: hostname)
                        print("MY NETWORK ADDRESS \(String(describing: address))")
                    }
                    if address == nil
                    {
                        if name == "pdp_ip0"
                        {
                            var addr = interface?.ifa_addr.pointee
                            
                            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                            getnameinfo(&addr!, socklen_t((interface?.ifa_addr.pointee.sa_len)!),
                                        &hostname, socklen_t(hostname.count),
                                        nil, socklen_t(0), NI_NUMERICHOST)
                            
                            address = String(cString: hostname)
                            print("MY NETWORK ADDRESS \(String(describing: address))")
                            
                        }
                        
                    }
                }
                ptr = ptr?.pointee.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        
        return address
    }
    
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
    
    func startListening() {
        oscClient.host = rwaCreatorIP
        oscClient.port = 8000
        oscServer.startListening()
    }
    
    func updateInverseElevationSwitch()
    {
        if(inverseElevation){
            inverseElevationSwitch.isOn = true
        }
        else {
            inverseElevationSwitch.isOn = false
        }
    }
    
    // Same titles the old Current Scene tab's Connect button showed
    func updateConnectBleButton()
    {
        if(headTrackerConnected) {
            if(useHeadTracker) {
                bleConnectButton.setTitle("Headtracker connected", for: UIControlState()) }
            else {
                bleConnectButton.setTitle("Using Device Orientation", for: UIControlState()) }
        }
        else {
            bleConnectButton.setTitle("Connect Headtracker", for: UIControlState())
        }
    }
    
    func updateStartStopButton()
    {
        if(rwagameloop.isRunning) {
            startStopButton.setTitle("Stop", for: UIControlState())
        }
        else {
            startStopButton.setTitle("Start", for: UIControlState())
        }        
    }
    
    func updateUseHeadtrackerSwitch()
    {
        if(useHeadTracker){
            useDeviceOrientation.setOn(true, animated: false)
        }
        else {
            useDeviceOrientation.setOn(false, animated: false)
        }
    }
    
    @objc func updateButtons()
    {
        updateUseHeadtrackerSwitch()
        updateStartStopButton()
        updateConnectBleButton()
        updateInverseElevationSwitch()
    }
    
    fileprivate func sendRegisterOscMessage() {
        if let adress = getWiFiAddress() {
            let message = F53OSCMessage(addressPattern: "/register", arguments: ["Gandalf", adress])
            print("register client")
            oscClient.send(message)
            self.startListening()
            coreLocationController?.locationManager.stopUpdatingLocation()
        }
    }
    
    @IBAction func registerAtMother(_ sender: UIButton)
    {
        sendDummyOscMessage();
        sendDummyOscMessage();
        
        if(!registered)
        {
            registered = true;
            register.setTitle("Unregister", for: UIControlState())
            sendRegisterOscMessage()
        }
        else
        {
            oscServer.stopListening()
            registered = false;
            register.setTitle("Register", for: UIControlState())
            coreLocationController?.locationManager.startUpdatingLocation()
        }
    }
    
    @IBAction func useNewHeadtracker(_ sender: UISwitch)
    {
        useHeadTracker = sender.isOn;
        let defaults = UserDefaults.standard
        var isOn = "false"
        if(useHeadTracker) {
            isOn = "true" }
        defaults.set(isOn, forKey: defaultsKeys.useHeadtracker)
        NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Connect Headtracker"), object: nil)
    }
    
    @IBAction func inverseEle(_ sender: UISwitch)
    {
        inverseElevation = sender.isOn;
        let defaults = UserDefaults.standard
        var isOn = "false"
        if(inverseElevation) {
            isOn = "true" }
        defaults.set(isOn, forKey: defaultsKeys.inverseElevation)
    }
    
    @IBAction func sendGPS(_ sender: UISwitch)
    {
        sendGPS2Creator = sender.isOn;
    }
    
    @IBAction func bleConnect(_ sender: UIButton)
    {
        if(!headTrackerConnected) {
            NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Connect Headtracker"), object: nil)
        }
    }
    
    @IBAction func start(_ sender: UIButton)
    {
        if(!rwagameloop.isRunning) {
            NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Start Game"), object: nil)
        }
        else {
            NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Stop Game"), object: nil)
        }
    }
    
    @IBAction func calibrateHeadtracker(_ sender: UIButton)
    {
        if(headTrackerConnected)
        {
            azimuthOffset = azimuthOrg
            elevationOffset = elevationOrg
        }
    }

    @IBAction func pdGain(_ sender: UISlider)
    {
        pdGainVal = pdGainSlider.value * 5.0
        PdBase.send(Float(pdGainVal), toReceiver: "rwamainvolume")
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
}
