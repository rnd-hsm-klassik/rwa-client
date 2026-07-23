//
//  CoreLocationController.swift
//  rwa client
//
//  Created by Admin on 29/12/15.
//  Copyright © 2015 beryllium design. All rights reserved.
//

import Foundation
import CoreLocation

class CoreLocationController:NSObject, CLLocationManagerDelegate{

    var locationManager:CLLocationManager = CLLocationManager()
    
    override init() {
        super.init()
        self.locationManager.delegate = self
        self.locationManager.requestAlwaysAuthorization()
        self.locationManager.allowsBackgroundLocationUpdates = true;
        self.locationManager.pausesLocationUpdatesAutomatically = false;
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        print("didChangeAuthorizationStatus")
        
        switch status {
        case .notDetermined:
            print(".NotDetermined")
            locationManager.requestWhenInUseAuthorization()
            break
            
        case .authorizedAlways:
            print(".Authorized")
            self.locationManager.startUpdatingLocation()
            break
            
        case .denied:
            print(".Denied")
            break
            
        default:
            print("Unhandled authorization status")
            break
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation])
    {
        if(!registered)
        {
            // With RTK positioning selected and the tracker delivering,
            // internal GPS stands by; it takes over automatically when the
            // tracker goes quiet (fallback, see Settings tab).
            if(useRtkGps) {
                if let at = ubloxUpdatedAt, Date().timeIntervalSince(at) < LiveTelemetrySource.freshnessWindow {
                    return
                }
            }
            print("Update Location")
            let location = locations.last! as CLLocation
            hero.location = location
            hero.coordinates = location.coordinate
            hero.timeSinceLastGpsUpdate = 0.0
            
            if(sendGPS2Creator)
            {
                print("Send to Creator")
                print (hero.coordinates.longitude)
                print (hero.coordinates.latitude)
                let message = F53OSCMessage(addressPattern: "/position", arguments: [Float32(hero.coordinates.longitude), Float32(hero.coordinates.latitude)])
                oscClient.send(message)
            }
        }
    }
}
