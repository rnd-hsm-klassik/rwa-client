//
//  RwaImport.swift
//  rwa client
//
//  Created by Thomas Resch on 05/01/16.
//  Copyright © 2016 beryllium design. All rights reserved.
//

import Foundation
import CoreLocation

class RwaImport:NSObject, XMLParserDelegate
{
    var xmlParser:XMLParser?
    var rwaGameFile:URL?
    var scenePtr:RwaScene?
    var statePtr:RwaState?
    var assetPtr:RwaAsset?
    var areaPtr:RwaArea?
    var currentElement: String?
    var stateCounter = 0
    var readPolygonCorners:Bool = false;
    var readExitOffsetCorners:Bool = false;
    var readChannelCoordinates:Bool = false;
    var currentChannelCoordinate: CLLocationCoordinate2D = CLLocationCoordinate2D();
    var currentCorner: CLLocationCoordinate2D = CLLocationCoordinate2D();
    
    func readRwa(_ name:String)
    {
        scenes.removeAll()
       // let parts = name.components(separatedBy: ".")
       // let filename = parts.first!.decomposedStringWithCanonicalMapping
        logger.info("Importing \(name)")
        
      //  let rwaGamePath = Bundle.main.path(forResource: filename, ofType: "rwa")
        rwaGameFile = URL(fileURLWithPath: name)
        xmlParser = XMLParser(contentsOf: rwaGameFile!)
        guard let parser = xmlParser else {
            logger.error("Import FAILED, file missing or unreadable: \(name)")
            return
        }
        parser.delegate = self
        if !parser.parse() {
            // scenes may be empty or partial now; the game will not start.
            logger.error("Import FAILED for \(name): \(parser.parserError?.localizedDescription ?? "unknown parser error")")
        }

        hero.loadGameScript()
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String)
    {
        if(string.isEmptyOrWhitespace()) {
            return }
        
        if(currentElement == "requiredstate")
        {
            statePtr?.requiredStates.append(string)
            //print("Found requiredState \(string)")
        }
        
        if(currentElement == "nextstate")
        {
            statePtr?.nextState = string
            //print("Found nextstate \(string) \(string.characters.count)")
        }
        
        if(currentElement == "nextscene")
        {
            statePtr?.nextScene = string
            //print("Found nextscene \(string)")
        }
        
        if(currentElement == "hintstate")
        {
            statePtr?.hintState = string
            //print("Found hintstate \(string)")
        }
        
        if( (currentElement == "lon") && readPolygonCorners)
        {
            let lon:Double = Double(string)!;
            currentCorner.longitude = lon
            // var latd:Double = Double(lat)!
        }
        
        if( (currentElement == "lat") && readPolygonCorners)
        {
            let lat:Double = Double(string)!;
            currentCorner.latitude = lat
            areaPtr?.corners!.append(currentCorner)

        }
        
        if( (currentElement == "lon") && readExitOffsetCorners)
        {
            let lon:Double = Double(string)!;
            currentCorner.longitude = lon
            // var latd:Double = Double(lat)!
        }
        
        if( (currentElement == "lat") && readExitOffsetCorners)
        {
            let lat:Double = Double(string)!;
            currentCorner.latitude = lat
            areaPtr?.exitOffsetCorners!.append(currentCorner)
            logger.debug("Read Exit Offset Corner");
            
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        
        currentElement = ""
        if(elementName == "corners")
        {
            readPolygonCorners = false;
        }
        
        if(elementName == "exitoffsetcorners")
        {
            readExitOffsetCorners = false;
        }
        
        if(elementName == "channelpositions")
        {
            readChannelCoordinates = false;
        }
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String])
    {
        var attributeDict = attributeDict
        currentElement = elementName
        
        if(elementName == "scene")
        {
            let newScene = RwaScene(name:"")
            let sceneName = attributeDict.removeValue(forKey: "name")
            logger.debug("Importing scene '\(sceneName ?? "<no name>")'")
            let lat = attributeDict.removeValue(forKey: "lat")!
            let lon = attributeDict.removeValue(forKey: "lon")!
            let level = attributeDict.removeValue(forKey: "level")!
            let areaType = attributeDict.removeValue(forKey: "areatype")!
            let fallbackDisabled = attributeDict.removeValue(forKey: "fallbackdisabled")!
            let minStayTime = attributeDict.removeValue(forKey: "minstaytime")!

            newScene.name = sceneName!
            newScene.areaType = Int(areaType)!
            newScene.level = Int(level)!
            newScene.fallbackDisabled = fallbackDisabled.toBool()!
            newScene.coordinates.latitude = Double(lat)!
            newScene.coordinates.longitude = Double(lon)!
            newScene.minStayTime = Double(minStayTime)!

            newScene.radius = Double(attributeDict.removeValue(forKey: "radius")!)!
            newScene.width = Double(attributeDict.removeValue(forKey: "width")!)!
            newScene.height = Double(attributeDict.removeValue(forKey: "height")!)!
            newScene.exitOffset = Double(attributeDict.removeValue(forKey: "exitoffset")!)!
            
            scenes.append(newScene)
            scenePtr = newScene;
            areaPtr = newScene;
            stateCounter = 0;
        }
        
        if(elementName == "state")
        {
            let newState = RwaState()
            let stateName = attributeDict.removeValue(forKey: "name")
            let stateType = attributeDict.removeValue(forKey: "type")
            let areaType = attributeDict.removeValue(forKey: "areatype")
            let defaultPlaybackType = attributeDict.removeValue(forKey: "defaultplaybacktype")
            let enterOnlyOnce = attributeDict.removeValue(forKey: "enteronlyonce")
            let leaveAfterAssetsFinish = attributeDict.removeValue(forKey: "leaveafterassetsfinish")
            let leaveOnlyAfterAssetFinish = attributeDict.removeValue(forKey: "leaveonlyafterassetsfinish")
            let timeOut = attributeDict.removeValue(forKey: "timeout")
            let minStayTime = attributeDict.removeValue(forKey: "minstaytime")
            let stateWithinState = attributeDict.removeValue(forKey: "statewithinstate")
            
            newState.stateName = stateName!
            newState.type = Int32(stateType!)!
            newState.areaType = Int(areaType!)!
            newState.defaultPlaybackType = Int(defaultPlaybackType!)!
            newState.enterOnlyOnce = (enterOnlyOnce?.toBool())!
            newState.stateWithinState = (stateWithinState?.toBool())!
            newState.leaveAfterAssetsFinish = (leaveAfterAssetsFinish?.toBool())!
            newState.leaveOnlyAfterAssetsFinish = (leaveOnlyAfterAssetFinish?.toBool())!
            newState.timeOut = Double(timeOut!)!
            newState.minStayTime = Double(minStayTime!)!
            if(Int(stateType!) == RWASTATETYPE_BACKGROUND)
            {
                scenePtr?.backgroundState = newState
            }
            
            //newState.coordinates.longitude = Double(attributeDict.removeValueForKey("lon")!)!
            
            scenePtr!.addState(newState)
            statePtr = newState
            areaPtr = newState
            
            stateCounter += 1;
            
        }
        
        if(elementName == "corners")
        {
            readPolygonCorners = true;
        }
        
        if(elementName == "exitoffsetcorners")
        {
            readExitOffsetCorners = true;
        }
        
        if(elementName == "channelpositions")
        {
            readChannelCoordinates = true;
        }
        
        if(readChannelCoordinates == true)
        {
            var channel: String
            for i in 0 ..< 64
            {
                channel = "channel\(i)"
                if(elementName == channel)
                {
                    //print("Found Coordinates for: \(channel)")
                    let lat = attributeDict.removeValue(forKey: "lat")!
                    let lon = attributeDict.removeValue(forKey: "lon")!
                    assetPtr?.channelCoordinates[i].latitude = Double(lat)!;
                    assetPtr?.channelCoordinates[i].longitude = Double(lon)!;
                    assetPtr?.individuellChannelPosition[i] = true;
                    
                    //print("asset lat: \(lat)")
                    break;
                }
            }
        }
        
        if(elementName == "gps")
        {
            let lat = attributeDict.removeValue(forKey: "lat")!
            statePtr?.coordinates.latitude = Double(lat)!
            
            let lon = attributeDict.removeValue(forKey: "lon")!
            statePtr?.coordinates.longitude = Double(lon)!
           // print("state lat: \(statePtr?.coordinates.latitude)")
            
            let radius = attributeDict.removeValue(forKey: "radius")!
            statePtr?.radius = Double(radius)!
            
            let width = attributeDict.removeValue(forKey: "width")!
            statePtr?.width = Double(width)!
            
            let height = attributeDict.removeValue(forKey: "height")!
            statePtr?.height = Double(height)!
            
            // RWA Creator does not export an enterOffset, and has no GUI for it,
            // only commented-out calls to not implemented functions setEnterOffset()
            // instead, the Player has an enterOffset hardcoded in RwaArea.enterOffset!
//            let enterOffset = attributeDict.removeValue(forKey: "enteroffset")!
//            statePtr?.enterOffset = Double(enterOffset)!
            
            let exitOffset = attributeDict.removeValue(forKey: "exitoffset")!
            statePtr?.exitOffset = Double(exitOffset)!
            
            let isGps = attributeDict.removeValue(forKey: "isgps")!
            statePtr?.isGpsState = isGps.toBool()!
        }
        
        if(elementName == "asset")
        {
            let newAsset = RwaAsset()
            let assetURL = attributeDict.removeValue(forKey: "url")
            let parts = assetURL!.components(separatedBy: "/")
            let assetName:String = ("\(parts.last!.decomposedStringWithCanonicalMapping)")
            newAsset.name = assetName
            
            let lat = attributeDict.removeValue(forKey: "lat")!
            newAsset.coordinates.latitude = Double(lat)!
            let lon = attributeDict.removeValue(forKey: "lon")!
            newAsset.coordinates.longitude = Double(lon)!
            
            let startlat = attributeDict.removeValue(forKey: "startpositionlat")!
            newAsset.startPosition.latitude = Double(startlat)!
            let startlon = attributeDict.removeValue(forKey: "startpositionlon")!
            newAsset.startPosition.longitude = Double(startlon)!
            
            let type = attributeDict.removeValue(forKey: "type")!
            newAsset.type = Int32(type)!
            
            newAsset.mute = (attributeDict.removeValue(forKey: "mute")?.toBool())!
            newAsset.headtrackerRelative2Source = (attributeDict.removeValue(forKey: "headtrackerrelative2source")?.toBool())!
            newAsset.hasCoordinates = (attributeDict.removeValue(forKey: "hascoordinates")?.toBool())!
            newAsset.alwaysPlayFromBeginning = (attributeDict.removeValue(forKey: "alwaysplayfrombeginning")?.toBool())!
            newAsset.fadeInTime = Int32(attributeDict.removeValue(forKey: "fadein")!)!
            newAsset.fadeOutTime = Int32(attributeDict.removeValue(forKey: "fadeout")!)!
            newAsset.crossfadeTime = Double(attributeDict.removeValue(forKey: "crossfadetime")!)!
            newAsset.duration = Double(attributeDict.removeValue(forKey: "duration")!)!
            newAsset.playbackType = Int32(attributeDict.removeValue(forKey: "playbacktype")!)!
            newAsset.dampingFunction = Int(attributeDict.removeValue(forKey: "damping")!)!
            newAsset.loop = (attributeDict.removeValue(forKey: "loop")?.toBool())!
            newAsset.loopUntilEndPosition = (attributeDict.removeValue(forKey: "loopuntilendposition")?.toBool())!
            newAsset.isExclusive = (attributeDict.removeValue(forKey: "isexclusive")?.toBool())!
            newAsset.gps2pd = (attributeDict.removeValue(forKey: "gps2pd")?.toBool())!
            newAsset.playOnce = (attributeDict.removeValue(forKey: "playonlyonce")?.toBool())!
            newAsset.rawSensors2pd = (attributeDict.removeValue(forKey: "rawsensors2pd")?.toBool())!
            newAsset.gain = Double(attributeDict.removeValue(forKey: "gain")!)!
            
            if let elevation = attributeDict.removeValue(forKey: "elevation") {
                newAsset.elevation = Float32(elevation)!
            }
            
            if let smoothDistance = attributeDict.removeValue(forKey: "smoothdist") {
                newAsset.smoothDistance = Double(smoothDistance)!
            }
            
            newAsset.autoRotate = (attributeDict.removeValue(forKey: "rotate")?.toBool())!
            newAsset.rotateFrequency = Double(attributeDict.removeValue(forKey: "rotatefrequency")!)!
            newAsset.multiChannelSourceRadius = Double(attributeDict.removeValue(forKey: "channelradius")!)!
            newAsset.moveFromStartPosition = (attributeDict.removeValue(forKey: "move")?.toBool())!
            newAsset.movementSpeed = Float(attributeDict.removeValue(forKey: "speed")!)!
            newAsset.fixedAzimuth = Double(attributeDict.removeValue(forKey: "fixedazimuth")!)!
            newAsset.fixedElevation = Double(attributeDict.removeValue(forKey: "fixedelevation")!)!
            newAsset.fixedDistance = Double(attributeDict.removeValue(forKey: "fixeddistance")!)!
            newAsset.minDistance = Double(attributeDict.removeValue(forKey: "mindistance")!)!
            
            newAsset.dampingFactor = Double(attributeDict.removeValue(forKey: "dampingfactor")!)!
            newAsset.dampingTrim = Double(attributeDict.removeValue(forKey: "dampingtrim")!)!
            newAsset.dampingMin = Double(attributeDict.removeValue(forKey: "dampingmin")!)!
            newAsset.dampingMax = Double(attributeDict.removeValue(forKey: "dampingmax")!)!
            newAsset.offset = Int32(attributeDict.removeValue(forKey: "offset")!)!
            newAsset.rotateOffset = Int(attributeDict.removeValue(forKey: "rotateoffset")!)!
            
            newAsset.calculateFadeOutAfterTime()
            newAsset.calculateDistanceAndBearingForMovement()
            assetPtr = newAsset;
            
            statePtr!.addAsset(newAsset)
            
            
            /* let parts2 = assetName.components(separatedBy: ".")
             let fileExtension = parts2.last!.decomposedStringWithCanonicalMapping
             
             if(fileExtension == "wav")
             {
             newAsset.type = Int32(RWAASSETTYPE_WAV)
             }
             
             if(fileExtension == "aif")
             {
             newAsset.type = Int32(RWAASSETTYPE_AIF)
             }*/
            
           
            //print("added \(assetName) to \(String(describing: statePtr?.stateName))" )
        }
        
    }
}
