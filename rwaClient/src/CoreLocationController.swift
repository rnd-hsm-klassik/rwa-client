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
        
        switch status {
        case .notDetermined:
            logger.debug("CLAuthorizationStatus: .NotDetermined")
            locationManager.requestWhenInUseAuthorization()
            break
            
        case .authorizedAlways:
            logger.debug("CLAuthorizationStatus: .Authorized")
            self.locationManager.startUpdatingLocation()
            break
            
        case .denied:
            logger.error("CLAuthorizationStatus: .Denied")
            break
            
        default:
            logger.error("CLAuthorizationStatus: Unhandled authorization status")
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
            let location = locations.last! as CLLocation
            hero.location = location
            hero.coordinates = location.coordinate
            hero.timeSinceLastGpsUpdate = 0.0
            
            if(sendGPS2Creator)
            {
                logger.debug("Sending to coordinates to Creator: (\(hero.coordinates.longitude), \(hero.coordinates.latitude)")
                let message = F53OSCMessage(addressPattern: "/position", arguments: [Float32(hero.coordinates.longitude), Float32(hero.coordinates.latitude)])
                oscClient.send(message)
            }
        }
    }
}
