//
//  Device.swift
//  BLEConnect
//
//  Created by Evan Stone on 8/15/16.
//  Copyright © 2016 Cloud City. All rights reserved.
//

import Foundation
import CoreBluetooth

struct Device {
    static let TransferService = "713D0000-503E-4C75-BA94-3148F18D941E"
    static let TransferCharacteristic = "713D0002-503E-4C75-BA94-3148F18D941E"
    
    static let TRACKERSERVICETX = "713D0002-503E-4C75-BA94-3148F18D941E"
    static let TRACKERSERVICERX = "713D0003-503E-4C75-BA94-3148F18D941E"
    static let TRACKERRAWDATA = "713D0004-503E-4C75-BA94-3148F18D941E"

    // Telemetry GATT service (PROJECT-PLAN.md §5.1) — cross-repo contract
    static let TelemetryService = "713D0100-503E-4C75-BA94-3148F18D941E"
    static let TelemetryTxCharacteristic = "713D0101-503E-4C75-BA94-3148F18D941E"
    static let TelemetryCtrlCharacteristic = "713D0102-503E-4C75-BA94-3148F18D941E"
    
    // Tags
    static let EOM = "{{{EOM}}}"
    
    // We have a 20-byte limit for data transfer
    static let notifyMTU = 20    
    static let centralRestoreIdentifier = "io.cloudcity.BLEConnect.CentralManager"
    static let peripheralRestoreIdentifier = "io.cloudcity.BLEConnect.PeripheralManager"
}
