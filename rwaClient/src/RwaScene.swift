//
//  RwaScene.swift
//  rwa client
//
//  Created by Admin on 02/01/16.
//  Copyright © 2016 beryllium design. All rights reserved.
//

import Foundation
import CoreLocation

class RwaScene:RwaArea {
    
    var name:String = ""
    var states: [RwaState] = []
    var currentState: RwaState = RwaState();
    var backgroundState: RwaState = RwaState();
    var fallbackState:RwaState = RwaState();
    var stateCounter: Int32 = 0;
    var location: String = ""
    var type: Int32 = 0
    var level: Int = -1
    var fallbackDisabled: Bool = false;
    var gain: Double = 1 // linear; multiplied into every asset of this scene by the game loop
    
    override init()
    {
    }
    
    init(name:String)
    {
        self.name = name
        //print(" The scene name is \(self.name)")
    }
    
    func clear()
    {
    
    }
    
    func addState()
    {
        
    }
    
    func addState(_ newState:RwaState)
    {
        states.append(newState)
        // print("Added State with name \(newState.stateName)")
    }
    
    func addState(_ name:String, stateNumber:Int32)
    {
        states.append(RwaState(name: name))
    }
    
    func addState(_ name:String, gpsCoordinates: CLLocation)
    {
        
    }
    
    func getState(_ name:String) ->RwaState?
    {
        for state in states
        {
            if(state.stateName == name)
            {
                return state
            }
        }
        return nil
    }

    func resetAssets()
    {
    }
    

    

    

    
    
    
    
    
    
    
    
    
    
    
    
   
}
