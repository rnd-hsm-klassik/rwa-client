//
//  RwaState.swift
//  rwa client
//
//  Created by Admin on 02/01/16.
//  Copyright © 2016 beryllium design. All rights reserved.
//

import Foundation
import CoreLocation

let RWASTATETYPE_FALLBACK = 1
let RWASTATETYPE_BACKGROUND = 2
let RWASTATETYPE_GPS = 3
let RWASTATETYPE_BLUETOOTH  = 4
let RWASTATETYPE_COMBINED = 5
let RWASTATETYPE_RANDOMGPS = 6
let RWASTATETYPE_HINT = 7
let RWASTATETYPE_OTHER = 8

let RWARANDOMGPS_CHURCH = 1
let RWARANDOMGPS_MONUMENT = 2

let RWASTATEATTRIBUTE_FOLLOWINGASSETS = 1
let RWASTATEATTRIBUTE_ENTERONLYONCE = 2
let RWASTATEATTRIBUTE_EXCLUSIVE = 3
let RWASTATEATTRIBUTE_LEAVEAFTERASSETSFINISH = 4
let RWASTATEATTRIBUTE_LEAVEONLYAFTERASSETSFINISH = 5
let RWASTATEATTRIBUTE_ENTERONLYAFTERASSETSFINISH = 6

class RwaState:RwaArea {

    //var myScene: RwaScene = RwaScene()
    var assets: [RwaAsset] = []
    var stateNumber: Int32 = -1
    var stateName: String = ""
    var requiredStates: [String] = []
    var isExclusive:Bool = false
    var enterOnlyOnce:Bool = false
    var leaveAfterAssetsFinish:Bool = false
    var leaveOnlyAfterAssetsFinish:Bool = false
    var enterOnlyAfterAssetsFinishe:Bool = false
    var isGpsState:Bool = false
    var isImmortal:Bool = false
    var blockUntilRadiusHasBeenLeft:Bool = false
    var stateWithinState:Bool = false
    var gain: Double = 1 // linear; multiplied into every asset of this state by the game loop
    
    var nextScene:String = ""
    var nextState:String = ""
    var hintState:String = ""
    var lastTouchedAsset: RwaAsset = RwaAsset()
    
    var type: Int32 = 0;

    var defaultPlaybackType = 0;
    var enterConditions: [String] = []
    var onEnter: [String] = []
    var pathway: [String] = []
    
    override init()
    {}
    
    init(name:String)
    {
        self.stateName = name
    }
    
    init(name:String, scene:RwaScene)
    {
        self.stateName = name
       // self.myScene = scene
    }
    
    func addAsset(_ name:String, type:Int32)
    {
        let newAsset = RwaAsset(fileName: name, type: type)
        assets.append(newAsset)
    }
    
    func addAsset(_ asset:RwaAsset)
    {
        assets.append(asset)
        //print("added asset: \(asset.fileNameString)")
    }
    
    func getAsset(_ path:String) -> RwaAsset
    {
        for asset in assets
        {
            if(asset.name == path)
            {
                return asset
            }
        }
       
        return RwaAsset()
    }
    
    func resetAssets()
    {
        for asset in assets
        {
            asset.blocked = false
        }
        
    }

}










