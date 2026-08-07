//
//  RwaAsset.swift
//  rwa client
//
//  Created by Admin on 02/01/16.
//  Copyright © 2016 beryllium design. All rights reserved.
//

import Foundation
import CoreLocation

let RWA_UNDETERMINED = 0

let RWAASSETTYPE_WAV = 1
let RWAASSETTYPE_AIF = 2
let RWAASSETTYPE_PD = 3
let RWAASSETTYPE_ITEM = 4
let RWAASSETTYPE_ENTITY = 5
let RWAASSETTYPE_OGG = 6

let RWAPOSITIONTYPE_ASSET = 1
let RWAPOSITIONTYPE_ASSETCHANNEL = 2
let RWAPOSITIONTYPE_ASSETSTARTPOINT = 3
let RWAPOSITIONTYPE_CURRENTASSETPOSITION = 4

let RWAPLAYBACKTYPE_MONO = 1
let RWAPLAYBACKTYPE_STEREO = 2
let RWAPLAYBACKTYPE_NATIVE = 3
let RWAPLAYBACKTYPE_BINAURAL = 4
let RWAPLAYBACKTYPE_BINAURALMONO = 4
let RWAPLAYBACKTYPE_BINAURALSTEREO = 5
let RWAPLAYBACKTYPE_BINAURALAUTO = 6
let RWAPLAYBACKTYPE_BINAURAL5CHANNEL = 7
let RWAPLAYBACKTYPE_BINAURAL_FABIAN = 8
let RWAPLAYBACKTYPE_BINAURALMONO_FABIAN = 8
let RWAPLAYBACKTYPE_BINAURALSTEREO_FABIAN = 9
let RWAPLAYBACKTYPE_BINAURALAUTO_FABIAN = 10
let RWAPLAYBACKTYPE_BINAURAL5CHANNEL_FABIAN = 11
let RWAPLAYBACKTYPE_BINAURAL7CHANNEL_FABIAN = 12
let RWAPLAYBACKTYPE_BINAURALSPACE = 13
let RWAPLAYBACKTYPE_CUSTOM1 = 14
let RWAPLAYBACKTYPE_CUSTOM2 = 15
let RWAPLAYBACKTYPE_CUSTOM3 = 16

let RWAASSETATTRIBUTE_ISEXCLUSIVE = 1
let RWAASSETATTRIBUTE_PLAYONCE = 2
let RWAASSETATTRIBUTE_ISACTIVE = 3
let RWAASSETATTRIBUTE_ISALIVE = 4
let RWAASSETATTRIBUTE_ISBLOCKED = 5
let RWAASSETATTRIBUTE_LOOP = 6
let RWAASSETATTRIBUTE_ELEVATION2PD = 7
let RWAASSETATTRIBUTE_ORIENTATION2PD = 8
let RWAASSETATTRIBUTE_RAWSENSORS2PD = 9
let RWAASSETATTRIBUTE_GPS2PD = 10
let RWAASSETATTRIBUTE_AUTOROTATE = 11
let RWAASSETATTRIBUTE_MOVEFROMSTARTPOSITION = 12
let RWAASSETATTRIBUTE_AUTOMOVE = 12
let RWAASSETATTRIBUTE_LOOPUNTILENDPOSITION = 13
let RWAASSETATTRIBUTE_DISTANCE2VOLUME = 14

class RwaAsset:NSObject
{
    // Number of spatial data channels (azimuthN/distanceN/elevationN) a playback
    // mode implies; 0 for modes without per-channel spatialisation data.
    // Mirrors RwaAsset1::channelCountForPlaybackType (rwa-creator/rwaasset1.cpp).
    static func channelCountForPlaybackType(_ playbackType: Int) -> Int
    {
        switch(playbackType)
        {
            case RWAPLAYBACKTYPE_MONO,
                 RWAPLAYBACKTYPE_STEREO,
                 RWAPLAYBACKTYPE_BINAURALMONO,
                 RWAPLAYBACKTYPE_BINAURALMONO_FABIAN,
                 RWAPLAYBACKTYPE_CUSTOM1,
                 RWAPLAYBACKTYPE_CUSTOM2,
                 RWAPLAYBACKTYPE_CUSTOM3:
                return 1

            case RWAPLAYBACKTYPE_BINAURALSTEREO,
                 RWAPLAYBACKTYPE_BINAURALSTEREO_FABIAN:
                return 2

            case RWAPLAYBACKTYPE_BINAURAL5CHANNEL,
                 RWAPLAYBACKTYPE_BINAURAL5CHANNEL_FABIAN:
                return 5

            case RWAPLAYBACKTYPE_BINAURAL7CHANNEL_FABIAN:
                return 7

            // AUTO/NATIVE dispatch on the file's channel count at patcher
            // selection, but the engine has never sent spatial data for them
            default: // AUTO, NATIVE, BINAURALSPACE, undetermined
                return 0
        }
    }

    // Angular offset (degrees, clockwise from the asset's forward direction) of
    // a channel's default position around the asset.
    // Mirrors RwaAsset1::channelOffsetForPlaybackType (rwa-creator/rwaasset1.cpp).
    static func channelOffsetForPlaybackType(_ playbackType: Int, _ channel: Int) -> Int
    {
        let stereoOffsets = [-60, 60]
        let fiveChannelOffsets = [-60, 0, 60, -120, 120]
        let sevenChannelOffsets = [-40, 0, 40, -80, 80, -120, 120]

        let count = channelCountForPlaybackType(playbackType)
        if(channel < 0 || channel >= count) {
            return 0
        }

        switch(count)
        {
            case 2: return stereoOffsets[channel]
            case 5: return fiveChannelOffsets[channel]
            case 7: return sevenChannelOffsets[channel]
            default: return 0
        }
    }

    // The number of spatial data channels the engine actually streams to this
    // asset: channelCountForPlaybackType, except Pd-patch assets never get less
    // than 1, and only 1 (raw head data) when "headtracker relative to source"
    // is off. Mirrors RwaAsset1::playbackChannelCount (rwa-creator/rwaasset1.cpp).
    func playbackChannelCount() -> Int
    {
        if(Int(type) == RWAASSETTYPE_PD && !headtrackerRelative2Source) {
            return 1
        }

        var count = RwaAsset.channelCountForPlaybackType(Int(playbackType))

        if(Int(type) == RWAASSETTYPE_PD && count < 1) {
            count = 1
        }

        return count
    }

    override init()
    {
        let tmp: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 0,longitude: 0)
        for _ in 0 ..< 64
        {
            channelCoordinates.append(tmp);
        }
    }
    
    init(fileName:String, type: Int32)
    {
        name = fileName
        self.type = Int32(type)
        
        let tmp: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 0,longitude: 0)
        for _ in 0 ..< 64
        {
            channelCoordinates.append(tmp);
        }
    }
    
    func calculateFadeOutAfterTime()
    {
        fadeOutAfter = duration-crossfadeTime
    }
    
    func calculateDistanceAndBearingForMovement()
    {
        distanceForMovement = calculateDistance(startPosition, p2: coordinates) * 1000
        bearingForMovement = -calculateBearing(startPosition, p2: coordinates)
    
    }
    
    var type:Int32 = -1
    var playbackType:Int32 = -1 // binaural, stereo, mono, etc..
    var dampingFunction: Int = 1
    var id:Int32 = -1
    var uniqueId: UUID = UUID();
    var fadeOutTime: Int32 = 0 // ms
    var fadeInTime: Int32 = 0 // ms
    var loopWaitTime: Int32 = 0 // ms
    var offset: Int32 = 0 // ms
    
    var mute:Bool = false
    var headtrackerRelative2Source:Bool = false
    var isExclusive:Bool = false // no other asset at the same time
    var reachedEndPosition:Bool = false
    var playOnce:Bool = false //
    var isActive:Bool = false     // currently active
    var patcherTag:Int32 = 0
    var patcherFile:UnsafeMutableRawPointer?
    var isAlive:Bool = false      // can be activated (in principle)
    var loop:Bool = false        // start again automatically while within state radius
    var blocked:Bool = false      // blocked, can't be activated (blocked by another client??)
    var blockedForever:Bool = false      // blocked, can't be activated (blocked by another client??)
    var rawSensors2pd:Bool = false
    var gps2pd:Bool = false
    var orientation2pd:Bool = false
    var elevation2pd:Bool = false
    var hasCoordinates:Bool = false  // if, else use state coordinates
    var alwaysPlayFromBeginning:Bool = false
    var numberOfChannels:Int32 = 1
    var multiChannelSourceRadius:Double = 0
    var gain: Double = 0
    var distanceForMovement: Double = 0
    var movingDistancePerTick: Double = 0
    var bearingForMovement: Double = 0
    var loopUntilEndPosition: Bool = false
    var autoRotate: Bool = false
    var duration: Double = 0
    var moveFromStartPosition: Bool = false
    var rotateOffsetPerTick: Float = 0
    var rotateFrequency: Double = 0
    var crossfadeTime: Double = 0
    var fadeOutAfter: Double = 0
    var dampingFactor: Double = 30
    var dampingTrim: Double = 2
    var dampingMin: Double = 0
    var dampingMax: Double = 1
    var smoothDistance: Double = 10
    var minDistance: Double = -1

    // playhead tracking
    var playheadPosition: Double = 0; // samples
    var playheadPositionWithoutOffset: Double = 0; // ms
    var updatePlayheadPosition:Bool = true;

    var channelCoordinates: [CLLocationCoordinate2D] = []
    var channelDistance = [Float](repeating: 0.0, count: 64)
    var channelBearing = [Float](repeating: 0.0, count: 64)
    var individuellChannelPosition = [Bool] (repeating: false, count: 64)
    var channelRotateFreq = [Float](repeating: 0.0, count: 64)
    var rotateOffset: Int = 0;
    var channelGain = [Float](repeating: 0.0, count: 64)
    var channelRotate = [Bool] (repeating: false, count: 64)
    var currentRotateAngleOffset: Float = 0
    var fixedAzimuth: Double = -1
    var fixedDistance: Double = -1
    var fixedElevation: Double = -1
    
    // other processed sensor data missing
    
    var timeOut:Int32 = -1  // timeOut in ms
    var fullPath:String = ""
    var name:String = ""
    var coordinates = CLLocationCoordinate2D()
    var currentPosition = CLLocationCoordinate2D()
    var startPosition = CLLocationCoordinate2D()
    var movementSpeed: Float = 0
    var waitTimeBeforeMovement : Float = 0
    var elevation:Float32 = 0
}
