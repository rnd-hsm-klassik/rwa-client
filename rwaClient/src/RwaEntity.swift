//
//  RwaEntity.swift
//  rwa client
//
//  Created by Admin on 05/01/16.
//  Copyright © 2016 beryllium design. All rights reserved.
//

import Foundation
import CoreLocation

var scenes: [RwaScene]  = []

class RwaEntity:NSObject
{
    struct AssetMapItem {
        var asset:RwaAsset
        var patcherTag:Int32
        init(_ asset_: RwaAsset, _ patcherTag_: Int32)
        {
            asset = asset_
            patcherTag = patcherTag_
        }
    };
    
    var name:String = ""
    var location:CLLocation = CLLocation()
    var coordinates:CLLocationCoordinate2D = CLLocationCoordinate2D()
    var timeSinceLastGpsUpdate:Double = 0.0;
    var disconnectedFromHeadtrackerSince = 0.0
    var azimuth:Double = 0     // head yaw, degrees clockwise from north, [0, 360)
    var elevation:Double = 0   // head pitch, degrees, positive up, (-180, 180] - not clamped
    var stepCount:Int = 0
    var currentScene:RwaScene?
    var currentState:RwaState?
    var timeInCurrentState:Double = 0
    var timeInCurrentScene:Double = 0
    var time:Float = 0
    var activeAssets: [UUID:AssetMapItem] = Dictionary()
    var backgroundAssets : [UUID:AssetMapItem] = Dictionary()
    var assets2Unblock: [RwaAsset] = []
    var visitedStates: [String] = []
    
    init(name:String)
    {
        self.name = name
    }
    
    func loadGameScript()
    {
        self.visitedStates.removeAll()
        if(!scenes.isEmpty)
        {
            self.currentScene = scenes[0]
            self.currentState = currentScene?.states[0]
        }
    }
    
    func isActiveAsset(_ name: UUID) -> Bool
    {
        let keyExists = activeAssets[name]
        
        if  keyExists != nil {
            return true }
        else {
            return false }
    }
    
    func removeActiveAsset(_ patcherTag: Int32)
    {
        for mapItem in self.activeAssets
        {
            if(mapItem.value.patcherTag == patcherTag)
            {
                activeAssets.removeValue(forKey: mapItem.key)
                return
                
            }
        }
    }
    
    func removeBackgroundAsset(_ patcherTag: Int32)
    {
        for mapItem in self.backgroundAssets
        {
            if(mapItem.value.patcherTag == patcherTag)
            {
                backgroundAssets.removeValue(forKey: mapItem.key)
                return
                
            }
        }
    }
    
    func getScene(sceneName:String) ->RwaScene
    {
        for scene in scenes
        {
            if(scene.name == sceneName)
            {
                return scene
                
            }
        }
        return RwaScene()
    }
}
