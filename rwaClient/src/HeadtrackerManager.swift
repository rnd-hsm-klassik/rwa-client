//
//  HeadtrackerManager.swift
//  rwa player
//
//  BLE central for the headset assembly: connection lifecycle, the tracker
//  text protocol, raw RTK position frames and the telemetry CBOR ingest.
//  Extracted from SecondViewController (the hidden "Current Scene" tab) and
//  owned by the AppDelegate.
//

import Foundation
import CoreBluetooth
import CoreLocation

/// Step detection shared by both acceleration sources: the headtracker's
/// linear-acceleration frames (HeadtrackerManager) and the phone's
/// accelerometer (SecondViewController.startQueuedUpdates). Operates on the
/// module globals (linAccel, linAccelAverage, step, stepCount).
class StepDetector {
    static let shared = StepDetector()

    var blockSteps = false

    func unblockSteps() {
        blockSteps = false
        logger.info("Steps: unblock")
    }

    func process() {
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
}

/// True while any BLE source is active: the headtracker as heading source
/// and/or the RTK tracker as position source. As long as this holds, the
/// central keeps trying to connect/reconnect to the assembly.
func bleAssemblyNeeded() -> Bool {
    return useHeadTracker || useRtkGps
}

/// True once a connection has existed since the last intentional teardown.
/// lets the Control tab say "Reconnecting..." instead of "Connecting...".
var headTrackerEverConnected = false

class HeadtrackerManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    var centralManager:CBCentralManager!
    var peripheral:CBPeripheral?
    var dataBuffer:NSMutableData = NSMutableData()
    /// Set on operator/settings-driven teardowns (disconnect(), retarget) so
    /// didDisconnectPeripheral can tell them apart from radio drops, which
    /// trigger an automatic reconnect. Consumed (reset) in didDisconnect.
    var intentionalDisconnect = false
    /// Consecutive didFailToConnect count; after 3 the retained peripheral is
    /// dropped and scanning takes over.
    var connectRetryCount = 0
    /// assemblyTargetName() captured when the connect was issued; a mismatch
    /// later means the operator retargeted in Settings mid-session.
    var targetNameAtConnect: String?
    /// Advertised BLE name of the assembly being connected (assembly_id in
    /// telemetry); nil while disconnected.
    var connectedAssemblyName: String?
    var rssiTimer:Timer?

    override init() {
        super.init()
        // The BLE axis of both notifications; SecondViewController observes
        // the same names for the heading axis (CoreMotion start/stop).
        NotificationCenter.default.addObserver(self, selector: #selector(self.connectHeadtracker), name: NSNotification.Name(rawValue: "Connect Headtracker"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.connectHeadtracker), name: NSNotification.Name(rawValue: "Game Loaded"), object: nil)
    }

    /// The central is long-lived: created once, reused for every (re)connect.
    /// Recreating it per request (the pre-extraction behavior) dropped the
    /// retained peripheral and any pending connect with it.
    func ensureCentralManager() {
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: nil)
        }
    }

    /// Idempotent: asserts the desired state instead of tearing down and
    /// rebuilding. A healthy connection survives unrelated settings changes;
    /// only a retarget or "no BLE source active" disconnects.
    @objc func connectHeadtracker() {
        if(bleAssemblyNeeded()) {
            ensureCentralManager()
            if let p = peripheral {
                if targetNameAtConnect == assemblyTargetName() && (p.state == .connected || p.state == .connecting) {
                    return
                }
                // Retargeted in Settings (or the reference is stale): drop
                // it and find the current target by scanning.
                headTrackerEverConnected = false
                if p.state == .connected {
                    // didDisconnect will fire and, with peripheral already
                    // nil, fall through to startScanning().
                    intentionalDisconnect = false
                    peripheral = nil
                    centralManager.cancelPeripheralConnection(p)
                    return
                }
                // A pending connect is cancelled without any delegate
                // callback, so fall through to the scan below.
                peripheral = nil
                centralManager.cancelPeripheralConnection(p)
            }
            if centralManager.state == .poweredOn {
                startScanning()
            }
            // else: centralManagerDidUpdateState starts scanning on poweredOn.
        }
        else {
            headTrackerConnecting = false
            headTrackerEverConnected = false
            disconnect()
            NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Update Buttons"), object: nil)
        }
    }

    func stopScanning() {
        if(centralManager != nil) {
            centralManager.stopScan()
        }
    }

    func startScanning() {
        if centralManager == nil || centralManager.state != .poweredOn {
            return
        }
        if centralManager.isScanning {
            logger.info("BT: Central Manager is already scanning.")
            return;
        }

        if(!bleAssemblyNeeded()) {
            logger.info("BT: No BLE source active (heading and position are internal).")
            return;
        }
        else {
            // Filtered on the transfer service (both assembly kinds expose it)
            // so discovery also works while the app is backgrounded or the
            // phone is locked (iOS silently delivers nothing there for an
            // unfiltered scan).
            centralManager.scanForPeripherals(withServices: [CBUUID(string: Device.TransferService)], options: nil)
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
            // Cancels a pending connect; no delegate callback fires for a
            // connection that was never established.
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }

        // From here on a real teardown happens. didDisconnect shouldn't
        // auto-reconnect. The flag survives the setNotifyValue(false) ->
        // didUpdateNotificationState -> cancelPeripheralConnection hop.
        intentionalDisconnect = true

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

    // MARK: - CBCentralManagerDelegate

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

        if central.state != .poweredOn {
            // Bluetooth off invalidates the peripherals without a reliable
            // didDisconnect, so the link state must be cleared here or it
            // goes stale (connected flag, DeviceHealth, RSSI).
            self.peripheral = nil
            rssiTimer?.invalidate()
            rssiTimer = nil
            DeviceTelemetryReceiver.shared.connectionReset()
            headTrackerConnected = false
            DeviceHealth.shared.setBLEConnected(false)
            DeviceHealth.shared.setAssembly(kind: nil, id: nil)
            connectedAssemblyName = nil
            // "We still want a connection": power-on resumes via scanning.
            headTrackerConnecting = bleAssemblyNeeded()
            NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Update Buttons"), object: nil)
            return
        }

        startScanning()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        // peripheral.name can be a stale GAP name from the system's Bluetooth
        // cache (renamed trackers keep their old name per phone, indefinitely);
        // the local name in the advertisement is always what the device
        // broadcasts right now, so match either.
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        logger.debug("BT: Discovered \(String(describing: peripheral.name)) (advertised: \(String(describing: advertisedName))) at \(RSSI)")
        // Target: the assembly override when set, else the unit label (§1.1).
        let target = assemblyTargetName()
        if(!target.isEmpty && (peripheral.name == target || advertisedName == target))
        {
            if self.peripheral != peripheral {

                // save a reference to the peripheral object so Core Bluetooth doesn't get rid of it
                self.peripheral = peripheral
                // What this assembly currently broadcasts (the cached GAP
                // name may be stale); reported as assembly_id in telemetry.
                connectedAssemblyName = advertisedName ?? peripheral.name
                // Stamped when the connect is issued (not only in didConnect)
                // so the idempotence check in connectHeadtracker recognises a
                // pending connect to the current target and leaves it alone.
                targetNameAtConnect = target

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
        connectRetryCount = 0
        targetNameAtConnect = assemblyTargetName()
        // Set by didDiscover on the scan path; on the direct reconnect path
        // only the (possibly cached) GAP name is available.
        if connectedAssemblyName == nil {
            connectedAssemblyName = peripheral.name
        }
        headTrackerConnected = true
        headTrackerConnecting = false
        headTrackerEverConnected = true
        DeviceHealth.shared.setBLEConnected(true)
        TelemetryService.shared?.recordAppEvent(name: "assembly_connected",
                                                data: ["assembly_id": connectedAssemblyName ?? ""])
        rssiTimer?.invalidate()
        rssiTimer = Timer.scheduledTimer(timeInterval: 2.0, target: self,
                                         selector: #selector(pollRSSI),
                                         userInfo: nil, repeats: true)
        NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Headtracker Connected"), object: nil)
        // Let the Control tab (which hosts the Connect button) refresh its title
        NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Update Buttons"), object: nil)
        dataBuffer.length = 0

        // IMPORTANT: Set the delegate property, otherwise we won't receive the discovery callbacks, like peripheral(_:didDiscoverServices)
        peripheral.delegate = self

        logger.info("BT: Looking for Transfer Service...")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logger.info("BT: Failed to connect to \(peripheral) (\(String(describing: error?.localizedDescription)))")
        connectRetryCount += 1
        if connectRetryCount < 3, let p = self.peripheral {
            // Immediate re-issue, no timers: connect failures are rare and
            // non-bursty, and timers don't fire while the app is suspended.
            centralManager.connect(p, options: nil)
        }
        else {
            connectRetryCount = 0
            self.peripheral = nil
            startScanning()
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logger.info("BT: Disconnected from Peripheral (\(String(describing: error?.localizedDescription)))")
        // Only on a real transition, not on failed reconnect attempts.
        if headTrackerConnected {
            TelemetryService.shared?.recordAppEvent(name: "assembly_disconnected",
                                                    data: ["assembly_id": connectedAssemblyName ?? "",
                                                           "reason": error?.localizedDescription ?? "requested"])
        }
        // A partially received telemetry frame must not be glued to bytes
        // from the next connection (the device also restarts its stream).
        DeviceTelemetryReceiver.shared.connectionReset()
        rssiTimer?.invalidate()
        rssiTimer = nil
        DeviceHealth.shared.setBLEConnected(false)
        DeviceHealth.shared.setAssembly(kind: nil, id: nil)
        connectedAssemblyName = nil
        headTrackerConnected = false
        hero.disconnectedFromHeadtrackerSince = 0.0;

        if intentionalDisconnect || !bleAssemblyNeeded() {
            // Operator/settings-driven teardown: stay disconnected.
            intentionalDisconnect = false
            self.peripheral = nil
            headTrackerConnecting = false
        }
        else if let p = self.peripheral, targetNameAtConnect == assemblyTargetName() {
            // Radio drop: re-issue the connect on the retained peripheral.
            // The pending connect never times out and survives backgrounding
            // and the lock screen. It completes the moment the assembly is
            // back in range / powered on.
            headTrackerConnecting = true
            logger.info("BT: Reconnecting to \(String(describing: p.name))")
            centralManager.connect(p, options: nil)
        }
        else {
            // No usable peripheral, or the target changed: scan again.
            self.peripheral = nil
            startScanning()
        }
        NotificationCenter.default.post(name: NSNotification.Name(rawValue: "Update Buttons"), object: nil)
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {

        logger.info("BT: Discovered Services!!!")

        if error != nil {
            logger.error("BT: Error discovering services: \(String(describing: error?.localizedDescription))")
            // Not disconnect(): this is a link problem, not an operator
            // teardown. cancel and let didDisconnect auto-reconnect.
            if let p = self.peripheral {
                centralManager.cancelPeripheralConnection(p)
            }
            return
        }

        if let services = peripheral.services {

            // Assembly kind from GATT: only the RTK headtracker has the
            // telemetry service; RWAHT has just the tracker service. The BLE
            // name says nothing about the kind, and data freshness
            // (freshnessWindow) is a positioning concept that must not be used
            // for it either.
            let isRtk = services.contains { $0.uuid == CBUUID(string: Device.TelemetryService) }
            DeviceHealth.shared.setAssembly(kind: isRtk ? .rtkHeadtracker : .headtracker,
                                            id: connectedAssemblyName)

            for service in services {
                logger.info("BT: Discovered service \(service)")

                // If we found either the transfer service, discover the
                // transfer characteristic plus the raw RTK position
                // characteristic (713D0004). The firmware sends high-precision
                // position there, not as "l" frames on the headtracker char.
                if (service.uuid == CBUUID(string: Device.TransferService)) {
                    peripheral.discoverCharacteristics([
                        CBUUID(string: Device.TransferCharacteristic),
                        CBUUID(string: Device.TRACKERRAWDATA)
                    ], for: service)
                }

                // Telemetry service: CBOR event feed
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

        // Telemetry frames are CBOR.
        // handle them before the UTF-8 text decode below.
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
                ubloxLat = Double(words[1])! * (1/10000000)
                ubloxLon = Double(words[2])! * (1/10000000)
                ubloxUpdatedAt = Date()

                // RTK positioning (Settings tab): tracker coordinates drive
                // the walk. OSC-registered mode still overrides everything.
                if(useRtkGps && !registered) {
                    hero.coordinates = CLLocationCoordinate2D(latitude: ubloxLat!, longitude: ubloxLon!)
                    hero.timeSinceLastGpsUpdate = 0.0
                }
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
                StepDetector.shared.process();

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
}
