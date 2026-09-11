//
//  HeadtrackerManager.swift
//  rwa player
//
//  BLE central for the headset assembly: connection lifecycle, the tracker
//  text protocol, raw RTK position frames, the telemetry CBOR ingest and,
//  since ADR-001, the app side of the correction loop (RTCM down to the
//  assembly, its GGA up). Extracted from SecondViewController (the hidden
//  "Current Scene" tab) and owned by the AppDelegate.
//

import Foundation
import CoreBluetooth
import CoreLocation
import os.signpost

/// Instruments timeline for the head-tracking path: one .event per received
/// heading frame here, one interval per game-loop Pd flush (RwaGameLoop).
let headtrackingSignpostLog = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "RWA Player",
                                    category: "headtracking")

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
    /// True once 713D0005 was discovered on this connection. Gates the ASCII
    /// heading branch: RWAHT >= 0.3.0 keeps sending ASCII for one connection-
    /// event round-trip after we subscribe to the binary characteristic, and
    /// those stray frames must be dropped, not double-applied.
    var binaryHeadingPresent = false
    var rssiTimer:Timer?

    // MARK: Corrections over BLE (ADR-001, PROJECT-PLAN.md §5.6), bleQueue

    /// 713D0006 once discovered on this connection; nil = no RTCM downlink
    /// (rtk-rover ≤ 0.47, or discovery still running).
    private var rtcmCharacteristic: CBCharacteristic?
    /// Caster bytes waiting for the link, in order.
    private var rtcmQueue = RtcmChunker()
    private var rtcmBytesWritten = 0
    /// The assembly's latest GGA (713D0007) and when it arrived. Quiet means
    /// the receiver has no fix, not a broken link (§5.6).
    private(set) var latestAssemblyGga: String?
    private(set) var latestAssemblyGgaAt: Date?
    /// The caster session (NtripClient), alive while the connected assembly
    /// offers the RTCM downlink and the caster settings are complete; the
    /// assembly is its only consumer, so it dies with the connection. Keyed
    /// on 713D0006 rather than on the assembly kind on purpose: a ≤ 0.47
    /// unit runs its own client on the same single-session username, and a
    /// second session from the phone would starve it.
    private var ntripClient: NtripClient?
    /// Settings edits arrive one field at a time; the restart is debounced
    /// so a full re-entry of the caster is one session, not five.
    private var pendingNtripRestart: DispatchWorkItem?

    override init() {
        super.init()
        // The BLE axis of both notifications; SecondViewController observes
        // the same names for the heading axis (CoreMotion start/stop).
        NotificationCenter.default.addObserver(self, selector: #selector(self.connectHeadtracker), name: NSNotification.Name(rawValue: "Connect Headtracker"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.connectHeadtracker), name: NSNotification.Name(rawValue: "Game Loaded"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.casterSettingsChanged), name: CasterSettings.didChange, object: nil)
    }

    /// All CoreBluetooth delegate callbacks run here, NOT on the main queue.
    /// Measured 2026-08-27 (radio-idle assembly, so not coex): main-queue
    /// delivery stalled heading frames 90–240 ms behind UI work (Diagnostics
    /// table reloads, map/UI timers), then flushed them as a burst. UI side
    /// effects and Timers hop back to main explicitly below.
    private let bleQueue = DispatchQueue(label: "ch.rwa.ble", qos: .userInitiated)

    /// The central is long-lived: created once, reused for every (re)connect.
    /// Recreating it per request (the pre-extraction behavior) dropped the
    /// retained peripheral and any pending connect with it.
    func ensureCentralManager() {
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: bleQueue)
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
            HeadtrackerManager.postOnMain("Update Buttons")
        }
    }

    /// UI-facing notifications must be posted on the main queue: observers
    /// touch UIKit, and delegate callbacks arrive on bleQueue.
    private static func postOnMain(_ name: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name(rawValue: name), object: nil)
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
            HeadtrackerManager.postOnMain("Update Buttons")
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
            stopRSSITimerOnMain()
            DeviceTelemetryReceiver.shared.connectionReset()
            resetCorrectionsLink()
            headTrackerConnected = false
            DeviceHealth.shared.setBLEConnected(false)
            DeviceHealth.shared.setAssembly(kind: nil, id: nil)
            connectedAssemblyName = nil
            // "We still want a connection": power-on resumes via scanning.
            headTrackerConnecting = bleAssemblyNeeded()
            HeadtrackerManager.postOnMain("Update Buttons")
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
        // Timers need the main run loop (and invalidate must happen on the
        // scheduling thread), so the RSSI poll lives on main.
        DispatchQueue.main.async {
            self.rssiTimer?.invalidate()
            self.rssiTimer = Timer.scheduledTimer(timeInterval: 2.0, target: self,
                                                  selector: #selector(self.pollRSSI),
                                                  userInfo: nil, repeats: true)
        }
        HeadtrackerManager.postOnMain("Headtracker Connected")
        // Let the Control tab (which hosts the Connect button) refresh its title
        HeadtrackerManager.postOnMain("Update Buttons")
        dataBuffer.length = 0
        binaryHeadingPresent = false
        HeadingStats.shared.reset()
        resetCorrectionsLink()

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
        resetCorrectionsLink()
        stopRSSITimerOnMain()
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
        HeadtrackerManager.postOnMain("Update Buttons")
    }

    private func stopRSSITimerOnMain() {
        DispatchQueue.main.async {
            self.rssiTimer?.invalidate()
            self.rssiTimer = nil
        }
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

            // Assembly kind from GATT: keyed on the RTK-only attributes, plus
            // the raw position characteristic (713D0004) as a fallback once
            // characteristics arrive.
            let kind = Device.assemblyKind(serviceUUIDs: services.map { $0.uuid },
                                           trackerCharacteristicUUIDs: [])
            DeviceHealth.shared.setAssembly(kind: kind, id: connectedAssemblyName)

            for service in services {
                logger.info("BT: Discovered service \(service)")

                // If we found either the transfer service, discover the
                // transfer characteristic plus the raw RTK position
                // characteristic (713D0004). The firmware sends high-precision
                // position there, not as "l" frames on the headtracker char.
                if (service.uuid == CBUUID(string: Device.TransferService)) {
                    peripheral.discoverCharacteristics([
                        CBUUID(string: Device.TransferCharacteristic),
                        CBUUID(string: Device.TRACKERBINARYHEADING),
                        CBUUID(string: Device.TRACKERRAWDATA),
                        CBUUID(string: Device.TRACKERRTCM),
                        CBUUID(string: Device.TRACKERGGA)
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

                // Binary heading (rtk-rover >= 0.46.0, RWAHT >= 0.3.0).
                // rtk-headtracker sends no ASCII; RWAHT silences its
                // ASCII path once this subscription activates.
                if characteristic.uuid == CBUUID(string: Device.TRACKERBINARYHEADING) {
                    logger.info("BT: Found binary heading characteristic, subscribing")
                    binaryHeadingPresent = true
                    peripheral.setNotifyValue(true, for: characteristic)
                }

                if characteristic.uuid == CBUUID(string: Device.TRACKERRAWDATA) {
                    logger.info("BT: Found RTK raw position, subscribing")
                    // Kind fallback: raw position is RTK-only, so its
                    // presence settles the kind even if the telemetry service
                    // was missed during service discovery.
                    DeviceHealth.shared.setAssembly(kind: .rtkHeadtracker,
                                                    id: connectedAssemblyName)
                    peripheral.setNotifyValue(true, for: characteristic)
                }

                if characteristic.uuid == CBUUID(string: Device.TelemetryTxCharacteristic) {
                    logger.info("BT: Found telemetry TX, subscribing")
                    peripheral.setNotifyValue(true, for: characteristic)
                }

                // Corrections over BLE (rtk-rover >= 0.48.0, §5.6): keep the
                // RTCM downlink for the writer, subscribe to the GGA uplink.
                if characteristic.uuid == CBUUID(string: Device.TRACKERRTCM) {
                    logger.info("BT: Found RTCM downlink")
                    rtcmCharacteristic = characteristic
                    DeviceHealth.shared.setRtcmDownlink(present: true)
                    startNtripClientIfPossible()
                }

                if characteristic.uuid == CBUUID(string: Device.TRACKERGGA) {
                    logger.info("BT: Found GGA uplink, subscribing")
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        }
    }

    // MARK: - RTCM writer (bleQueue)

    /// Feed caster bytes to the assembly; any thread. Order is the only
    /// framing (§5.6), so the queue is FIFO with drop-oldest beyond a few
    /// epochs (RtcmChunker), and the bytes go out in writes of at most the
    /// ATT payload size as CoreBluetooth accepts them.
    func writeRtcm(_ data: Data) {
        bleQueue.async {
            self.rtcmQueue.append(data)
            self.pumpRtcm()
        }
    }

    /// Drains the queue while the peripheral accepts writes without
    /// response; resumed from peripheralIsReady(toSendWriteWithoutResponse:).
    /// maximumWriteValueLength is 20 until the MTU exchange (~0.2 s after
    /// connect) and 514 at the MTU 517 iOS negotiates: whatever it is now.
    private func pumpRtcm() {
        guard let peripheral = peripheral, peripheral.state == .connected,
              let characteristic = rtcmCharacteristic, !rtcmQueue.isEmpty else { return }
        let maxLength = peripheral.maximumWriteValueLength(for: .withoutResponse)
        while peripheral.canSendWriteWithoutResponse,
              let chunk = rtcmQueue.nextChunk(maxLength: maxLength) {
            peripheral.writeValue(chunk, for: characteristic, type: .withoutResponse)
            rtcmBytesWritten += chunk.count
        }
        DeviceHealth.shared.setRtcmWritten(total: rtcmBytesWritten, dropped: rtcmQueue.droppedBytes)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        pumpRtcm()
    }

    /// Connect and disconnect: the downlink and the GGA belong to one
    /// connection, and queued corrections are stale by the time a new one
    /// exists. The caster session ends with its only consumer.
    private func resetCorrectionsLink() {
        stopNtripClient()
        rtcmCharacteristic = nil
        rtcmQueue.removeAll()
        latestAssemblyGga = nil
        latestAssemblyGgaAt = nil
        DeviceHealth.shared.setRtcmDownlink(present: false)
    }

    // MARK: - NTRIP client lifecycle (bleQueue)

    /// Opens the caster session once the RTCM downlink exists and the
    /// settings are complete. Called on discovery of 713D0006 and after a
    /// settings change; a no-op while a session is already running.
    private func startNtripClientIfPossible() {
        guard ntripClient == nil, rtcmCharacteristic != nil else { return }
        let settings = CasterSettings.load()
        guard settings.isComplete else {
            logger.info("ntrip: caster settings incomplete, no session (Settings ▸ Caster)")
            DeviceHealth.shared.setNtrip(state: nil, caster: nil)
            return
        }
        let client = NtripClient(settings: settings, appVersion: DeviceHealth.appVersionShort)
        client.onRtcm = { [weak self] data in
            self?.writeRtcm(data)   // hops to bleQueue itself
        }
        client.ggaSeed = {
            // The phone's own fix, until the assembly delivers a GGA
            // (ADR-001 §2, the cold-boot fix: a VRS streams nothing
            // without a position). nil until CoreLocation has delivered.
            guard let location = lastInternalLocation else { return nil }
            return Ntrip.gga(latitude: location.coordinate.latitude,
                             longitude: location.coordinate.longitude,
                             altitude: location.verticalAccuracy >= 0 ? location.altitude : 0,
                             at: location.timestamp)
        }
        client.onStatus = { status in
            DeviceHealth.shared.setNtrip(state: status.state.rawValue,
                                         reconnects: status.reconnects,
                                         bytesRx: status.bytesRx)
        }
        client.onProgress = { bytesRx in
            DeviceHealth.shared.setNtripBytesRx(bytesRx)
        }
        client.onError = { reason in
            DeviceHealth.shared.setNtripError(reason)
        }
        ntripClient = client
        DeviceHealth.shared.setNtrip(state: "connecting", caster: settings.endpointDescription)
        // A GGA that arrived before the client existed is still the best
        // position for the VRS.
        if let gga = latestAssemblyGga {
            client.updateAssemblyGga(gga)
        }
        client.start()
    }

    private func stopNtripClient() {
        guard let client = ntripClient else { return }
        ntripClient = nil
        client.stop()
        DeviceHealth.shared.setNtrip(state: nil, caster: nil)
    }

    /// Settings ▸ Caster edited (posted on main). Restart the session with
    /// the new settings, debounced; the bookkeeping lives on bleQueue like
    /// the rest of the corrections state.
    @objc private func casterSettingsChanged() {
        bleQueue.async {
            self.pendingNtripRestart?.cancel()
            let restart = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.pendingNtripRestart = nil
                self.stopNtripClient()
                self.startNtripClientIfPossible()
            }
            self.pendingNtripRestart = restart
            self.bleQueue.asyncAfter(deadline: .now() + 2, execute: restart)
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

        // GGA uplink (713D0007, rtk-rover >= 0.48.0): the receiver's own
        // fix-quality sentence at <= 1 Hz, kept for the NTRIP client, which
        // forwards it to the caster (§5.6).
        if characteristic.uuid == CBUUID(string: Device.TRACKERGGA) {
            guard let sentence = Device.parseGgaSentence(value) else {
                logger.debug("BT: malformed GGA notification (\(value.count) B)")
                return
            }
            latestAssemblyGga = sentence
            latestAssemblyGgaAt = Date()
            DeviceHealth.shared.setAssemblyGgaReceived()
            ntripClient?.updateAssemblyGga(sentence)
            return
        }

        // Binary heading frames (713D0005, rtk-rover >= 0.46.0 and RWAHT >=0.3.0):
        // the active heading feed whenever the characteristic exists;
        // only pre-0.3.0 RWAHT keeps the ASCII path below.
        if characteristic.uuid == CBUUID(string: Device.TRACKERBINARYHEADING) {
            guard let frame = Device.parseBinaryHeadingFrame(value) else {
                logger.debug("BT: malformed binary heading frame (\(value.count) B)")
                return
            }
            // Same gate as the ASCII heading branch: with Internal heading
            // selected, a tracker connected for RTK positioning must not
            // overwrite the CoreMotion heading or double-count steps.
            if useHeadTracker {
                os_signpost(.event, log: headtrackingSignpostLog, name: "heading_frame")
                // Full float precision from the wire (Q14 quaternion, sub-0.01 deg);
                // rounding happens only where degrees are displayed.
                let azimuthOrgNew = wrap360(Double(frame.azimuthDeg))
                HeadingStats.shared.record(format: .binary)
                applyHeadingSample(azimuthOrgNew: azimuthOrgNew,
                                   elevationOrgNew: Double(frame.elevationDeg),
                                   linAccelNew: frame.linAccelZ)
            }
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
            // Coordinates are multi-word values read by the main-thread game loop.
            // Apply on main (<= 10 Hz, cheap) rather than risk a torn lat/lon pair from the BLE queue.
            DispatchQueue.main.async {
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
                guard let lat = Double(words[1]), let lon = Double(words[2]) else { return }
                DispatchQueue.main.async {
                    ubloxLat = lat * (1/10000000)
                    ubloxLon = lon * (1/10000000)
                    ubloxUpdatedAt = Date()

                    // RTK positioning (Settings tab): tracker coordinates drive
                    // the walk. OSC-registered mode still overrides everything.
                    if(useRtkGps && !registered) {
                        hero.coordinates = CLLocationCoordinate2D(latitude: ubloxLat!, longitude: ubloxLon!)
                        hero.timeSinceLastGpsUpdate = 0.0
                    }
                }
            }
            // RWAHT >= 0.3.0 selects one heading path per connection by CCCD
            // subscription, but the switchover to binary takes one
            // connection-event round-trip, so a few ASCII heading frames can
            // still arrive right after we subscribe to 713D0005. Drop them so
            // they don't double-count steps against the binary feed.
            else if binaryHeadingPresent {
                logger.debug("BT: dropping ASCII heading frame (binary heading active)")
            }
            // Heading frames only count while the headtracker is the heading
            // source: with Internal selected a tracker connected for RTK
            // positioning would otherwise overwrite the CoreMotion heading
            // (and double-count steps) on every frame.
            else if(useHeadTracker)
            {
                // Parsed as decimals (the old `.digits` + intValue path dropped the
                // fraction and the sign of a negative pitch).
                let trim = CharacterSet.whitespacesAndNewlines
                guard let azimuthParsed = Double(words[0].trimmingCharacters(in: trim)),
                      let elevationParsed = Double(words[1].trimmingCharacters(in: trim)) else {
                    logger.debug("BT: malformed ASCII heading frame")
                    return
                }
                let linAccTmp = words[2]

                os_signpost(.event, log: headtrackingSignpostLog, name: "heading_frame")
                let azimuthOrgNew = wrap360(azimuthParsed)
                HeadingStats.shared.record(format: .ascii)
                applyHeadingSample(azimuthOrgNew: azimuthOrgNew,
                                   elevationOrgNew: elevationParsed,
                                   linAccelNew: NSString(string: linAccTmp).floatValue)
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

    /// Apply one decoded heading sample to the module globals; both wire
    /// formats (binary 713D0005 and ASCII 713D0002) land here, so calibration
    /// offsets, step detection and the hero update behave identically.
    /// Callers gate on useHeadTracker.
    ///
    /// Runs on bleQueue, writing the globals off-main on purpose: hopping to
    /// main would re-queue the sample behind the very UI work the dedicated
    /// queue exists to bypass. The globals are word-sized Int/Float, and the
    /// CoreMotion heading path (SecondViewController.startQueuedUpdates)
    /// already writes them from a background OperationQueue the same way.
    private func applyHeadingSample(azimuthOrgNew: Double, elevationOrgNew: Double, linAccelNew: Float) {
        guard azimuthOrgNew.isFinite, elevationOrgNew.isFinite else { return }
        azimuthOrg = azimuthOrgNew
        azimuth = wrap360(azimuthOrg - azimuthOffset)

        elevationOrg = elevationOrgNew
        var pitch = elevationOrg - elevationOffset
        if(inverseElevation) {
            pitch = -pitch;
        }
        // No clamp: pitch past vertical is a valid pose (mirrors RwaEntity::setElevation in
        // the Creator); the source-relative elevation comes out of calculateRelativeDirection.
        elevation = wrap180(pitch)

        linAccel = linAccelNew
        linAccelAverage = Float(averageAccel.average(value: Double(linAccel)))
        StepDetector.shared.process();

        hero.azimuth = azimuth
        hero.elevation = elevation
        hero.stepCount = stepCount
        trackerHeadingUpdatedAt = Date()
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
