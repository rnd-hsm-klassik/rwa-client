//
//  CoreLocationController.swift
//  rwa client
//
//  Created by Admin on 29/12/15.
//  Copyright © 2015 beryllium design. All rights reserved.
//

import Foundation
import CoreLocation

// The phone's own GPS as telemetry sees it, set on every delivered fix;
// also while the RTK tracker or the Creator drives the hero (only the hero
// update below is gated). AppTelemetrySampler emits the continuous `phone`
// gnss_fix stream from these; that stream deliberately runs alongside the
// RTK headtracker's own fixes, so the two positioning systems can be
// compared over the same walk (PROJECT-PLAN.md §4.3).
var lastInternalLocation: CLLocation?
var locationUpdatedAt: Date?

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
        let location = locations.last! as CLLocation
        // Telemetry sees every fix (see the globals above); only whether the
        // fix drives the hero is decided below.
        lastInternalLocation = location
        locationUpdatedAt = Date()

        if(!registered)
        {
            // With RTK positioning selected and the headset assembly delivering,
            // internal GPS stands by; it takes over automatically when the
            // headset assembly goes quiet (fallback, see Settings tab).
            if(useRtkGps) {
                if let at = ubloxUpdatedAt, Date().timeIntervalSince(at) < PositioningPolicy.freshnessWindow {
                    return
                }
            }
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
