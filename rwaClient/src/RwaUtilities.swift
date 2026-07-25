//
//  RwaUtilities.swift
//  rwa client
//
//  Created by Admin on 07/01/16.
//  Copyright © 2016 beryllium design. All rights reserved.
//

import Foundation
import CoreLocation
import UIKit
let RWA_EARTHRADIUS:Double = 6378137

class MovingAverage {
    var samples: Array<Double>
    var period = 128
    var currentSample = 127;
    var oldestSample = 0;
    var sum: Double = 0;
    
    init(period: Int = 127) {
        self.period = period
        samples = [Double](repeating: 0.0, count: 128)
    }
    
    func average(value: Double) -> Double {
        samples[currentSample] = value;
        sum = sum + samples[currentSample] - samples[oldestSample]
        let average = sum / Double(period);
        currentSample = (currentSample + 1) & 127
        oldestSample = (oldestSample + 1) & 127
        
        return average
    }
}

func degrees2radians(_ degrees:Double) ->Double
{
    return degrees * (Double.pi/180)
}

func radians2degrees(_ radians:Double) -> Double
{
    return radians * (180/Double.pi);
}

// calculates a new coordinate from origin coordinates with radius and bearingInDegrees

func calculateDestination(_ coordinates:CLLocationCoordinate2D, _ radius:Double, _ bearingInDegrees: Double) -> CLLocationCoordinate2D
{
    let bearing = degrees2radians(bearingInDegrees)
    let lat1 = degrees2radians(coordinates.latitude)
    let long1 = degrees2radians(coordinates.longitude)
    let delta = radius/RWA_EARTHRADIUS
    
    let lat2 = radians2degrees(asin(sin(lat1) * cos(delta) + cos(lat1) * sin(delta) * cos(bearing)));
    let long2:Double = radians2degrees(fmod( (long1 - asin(sin(bearing)*sin(delta) / cos(lat1)) + Double.pi), (2*Double.pi)) - Double.pi);

    return CLLocationCoordinate2D(latitude: lat2, longitude: long2)
}

// calculates distance between p1 and p2 in kilometers

func calculateDistance(_ p1:CLLocationCoordinate2D, p2:CLLocationCoordinate2D) -> Double
{
    let R = 6373.0
    let lat1 = degrees2radians(p1.latitude)
    let lat2 = degrees2radians(p2.latitude)
    let dlon = degrees2radians(p2.longitude-p1.longitude)
    let dlat = degrees2radians(p2.latitude-p1.latitude)
    let a = pow((sin(dlat/2)),2) + cos(lat1) * cos(lat2) * pow((sin(dlon/2)),2)
    let c = 2 * atan2( sqrt(a), sqrt(1-a) ) ;
    let d = R * c;
    return d;
}

func calculateDistanceInMeters(_ p1:CLLocationCoordinate2D, p2:CLLocationCoordinate2D) -> Double
{
    let R = 6373000.0
    let lat1 = degrees2radians(p1.latitude)
    let lat2 = degrees2radians(p2.latitude)
    let dlon = degrees2radians(p2.longitude-p1.longitude)
    let dlat = degrees2radians(p2.latitude-p1.latitude)
    let a = pow((sin(dlat/2)),2) + cos(lat1) * cos(lat2) * pow((sin(dlon/2)),2)
    let c = 2 * atan2( sqrt(a), sqrt(1-a) ) ;
    let d = R * c;
    return d;
}

func calculateDistanceWithAltitude(_ p1:Double, p2:Double) -> Double
{
    let d = sqrt(pow(p1,2) + pow(p2, 2))
    return d;
}

func calculateElevationEasy(_ p1:CLLocationCoordinate2D, p2:CLLocationCoordinate2D, elevation:Double, headDirection:Double) -> Double
{
    let d = calculateDistanceInMeters(p1, p2: p2)
    let vd = elevation
    var relativeElevation = atan(vd/d)
    relativeElevation = radians2degrees(relativeElevation)
    relativeElevation -= headDirection;
    return relativeElevation
}

// calculates bearing between p1 and p2

func calculateBearing(_ p1:CLLocationCoordinate2D, p2:CLLocationCoordinate2D) -> Double
{
    let phi1 = degrees2radians(p1.latitude);
    let phi2 = degrees2radians(p2.latitude);
    let lam1 = degrees2radians(p1.longitude);
    let lam2 = degrees2radians(p2.longitude);
    
    let radians = atan2(sin(lam2-lam1)*cos(phi2),cos(phi1)*sin(phi2) - sin(phi1)*cos(phi2)*cos(lam2-lam1));
    let degrees = radians2degrees(radians);
    return (degrees+180).truncatingRemainder(dividingBy: 360);
}

// calculates bearing between p1 and p2 with head orientation

func calculateBearing(_ p1:CLLocationCoordinate2D, p2:CLLocationCoordinate2D, headDirection: Double) -> Double
{
    let phi1 = degrees2radians(p1.latitude);
    let phi2 = degrees2radians(p2.latitude);
    let lam1 = degrees2radians(p1.longitude);
    let lam2 = degrees2radians(p2.longitude);
    
    let radians = atan2(sin(lam2-lam1)*cos(phi2),cos(phi1)*sin(phi2) - sin(phi1)*cos(phi2)*cos(lam2-lam1));
    var degrees = radians2degrees(radians);
    degrees -= headDirection
    degrees += 360
    return (degrees+180).truncatingRemainder(dividingBy: 360);
}

// checks whether coordinate p is within polygon consisting of corners

func coordinateWithinPolygon(_ p:CLLocationCoordinate2D,_ corners: [CLLocationCoordinate2D]) -> Bool
{
    var oddNodes: Bool = false
    var j:Int = corners.count-1
    
    for i in 0 ..< corners.count
    {
        if ( (corners[i].latitude < p.latitude && corners[j].latitude >= p.latitude) ||  (corners[j].latitude<p.latitude && corners[i].latitude>=p.latitude ))
        {
            if (corners[i].longitude+(p.latitude-corners[i].latitude)/(corners[j].latitude-corners[i].latitude)*(corners[j].longitude - corners[i].longitude) < p.longitude)
            {
                oddNodes = !oddNodes;
            }
        }
        j=i;
    }
    
    return oddNodes;
}

// checks whether coordinate p is within rectangle with center and width and height (in meters)

func coordinateWithinRectangle(_ p:CLLocationCoordinate2D,_ center:CLLocationCoordinate2D,_ width: Double,_ height: Double) -> Bool
{
    let testx = p.longitude
    let testy = p.latitude
    
    let w = calculateDestination(center, width/2, 90);
    let e = calculateDestination(center, width/2, 270);
    
    var nw:CLLocationCoordinate2D =  calculateDestination(w, height/2, 0) ;
    
    if(nw.longitude < 0)
    {
        nw.longitude = nw.longitude + 360;
    }
    
    var sw:CLLocationCoordinate2D = (calculateDestination(w, height/2, 180) );
    if(sw.longitude < 0)
    {
        sw.longitude = sw.longitude + 360;
    }
    
    var ne:CLLocationCoordinate2D = (calculateDestination(e, height/2, 0) );
    if(ne.longitude < 0)
    {
        ne.longitude = ne.longitude + 360;
    }
    
    var se = (calculateDestination(e, height/2, 180) );
    if(se.longitude < 0)
    {
        se.longitude = se.longitude + 360;
    }
    
    if(testx > nw.longitude && testx < ne.longitude && testy > se.latitude && testy < ne.latitude) {
        return true }
    else {
        return false }
}

func boolean2Double(_ booleanValue: Bool) -> Double
{
    if(booleanValue) {
        return 1.0 }
    else {
        return 0.0 }
}

extension FileManager {
    
    static public func lastModified(fileUrl: URL) -> Date
    {
        // let aWeekAgo = calendar.date(byAdding: .day, value: -7, to: Date())!
        do {
            let resources = try fileUrl.resourceValues(forKeys: [.contentModificationDateKey])
            let modificationDate = resources.contentModificationDate!
            return modificationDate
        }
        
        catch {
            print(error)
        }
        return Date(timeIntervalSince1970: Foundation.TimeInterval(0))
    }
    
    static public func createDirectory(myDir: URL)
    {
        var isDir:ObjCBool = true
        do {
            if !FileManager.default.fileExists(atPath: myDir.relativePath, isDirectory: &isDir) {
                try FileManager.default.createDirectory(at: myDir, withIntermediateDirectories: true)
            }
        }
        catch {
            logger.error("Cannot create Folder item at \(myDir.relativePath): \(error)")
        }
    }
    
    open func removeIfExists(srcURL: URL)
    {
        do {
            if FileManager.default.fileExists(atPath: srcURL.path) {


                    try FileManager.default.removeItem(at: srcURL)
                logger.debug("File exists, removing it!")
         
            }
            
    
        } catch (let error) {
            logger.error("Cannot remove item \(srcURL): \(error)")

        }
        
    }

    open func secureCopyItem(at srcURL: URL, to dstURL: URL) -> Bool
    {
        do {
            if FileManager.default.fileExists(atPath: dstURL.path) {
                let srcModDate = FileManager.lastModified(fileUrl: srcURL)
                let dstModDate = FileManager.lastModified(fileUrl: dstURL)
                
                if(srcModDate > dstModDate) {
                    try FileManager.default.removeItem(at: dstURL)
                    logger.info("Found newer version, removed old")
                }
                else {
                    logger.info("File exists, no update necessary (\(dstURL))")
                    return false
                }
            }
            
            try FileManager.default.copyItem(at: srcURL, to: dstURL)
        } catch (let error) {
            logger.error("Cannot copy item at \(srcURL) to \(dstURL): \(error)")
            return false
        }
        return true
    }
}

extension String {
    func toBool() -> Bool? {
        switch self {
        case "True", "true", "yes", "1":
            return true
        case "False", "false", "no", "0":
            return false
        default:
            return nil
        }
    }
}

extension String {
    func isEmptyOrWhitespace() -> Bool
    {
        if(self.isEmpty || self.trimmingCharacters(in: .whitespaces).isEmpty) {
            return true
        }
        
        return false
    }
}

extension String  {
    func isNumber() -> Bool
    {
        if( !self.isEmpty &&  self.rangeOfCharacter(from: CharacterSet.decimalDigits.inverted) == nil ) {
            return true
        }
        return false
    }
    
    func fileExists() -> Bool {
          return FileManager().fileExists(atPath: self)
    }
    
    func removeFileExtension() -> String
    {
        var components = self.components(separatedBy: ".")
        if components.count > 1 { // If there is a file extension
          components.removeLast()
          return components.joined(separator: ".")
        } else {
            return components[0]
        }
    }
    
    var digits: String {
        return components(separatedBy: CharacterSet.decimalDigits.inverted)
            .joined()
    }
}

extension UIViewController {
     func sendDummyOscMessage() {
        let message = F53OSCMessage(addressPattern: "/dummy", arguments: ["Gandalf", "dummy"])
        oscClient.send(message)
        coreLocationController?.locationManager.stopUpdatingLocation()
    }

    /// Points the OSC client/server at the configured rwaCreator and starts
    /// listening. The receiver (F53OSCPacketDestination) is set separately by
    /// whichever controller owns message handling — currently the Control tab.
    func startOscListening() {
        oscClient.host = rwaCreatorIP
        oscClient.port = 8000
        oscServer.startListening()
    }

    /// Registers or unregisters with rwaCreator, mirroring the old Control
    /// Data tab's Register button. Flips the `registered` global; callers
    /// refresh their own UI from it afterwards. Shared here so both the
    /// Settings tab (the button's new home) and the Control tab's resume
    /// logic go through one path.
    func toggleCreatorRegistration() {
        sendDummyOscMessage()
        sendDummyOscMessage()

        if !registered {
            registered = true
            if let adress = getWiFiAddress() {
                let message = F53OSCMessage(addressPattern: "/register", arguments: ["Gandalf", adress])
                logger.debug("OSC: register client")
                oscClient.send(message)
                startOscListening()
                coreLocationController?.locationManager.stopUpdatingLocation()
            }
        } else {
            oscServer.stopListening()
            registered = false
            coreLocationController?.locationManager.startUpdatingLocation()
        }
    }

    /// Local IPv4 address (Wi-Fi first, cellular as fallback) — sent to
    /// rwaCreator on /register so it knows where to reply.
    func getWiFiAddress() -> String? {
        var address: String?

        // Get list of all interfaces on the local machine:
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        if getifaddrs(&ifaddr) == 0 {

            // For each interface ...
            var ptr = ifaddr
            while ptr != nil {
                let interface = ptr?.pointee

                // Check for IPv4 interface:
                let addrFamily = interface?.ifa_addr.pointee.sa_family
                if addrFamily == UInt8(AF_INET) {

                    // Check interface name:
                    let name = String(cString: (interface?.ifa_name)!)
                    if name == "en0" {
                        // Convert interface address to a human readable string:
                        var addr = interface?.ifa_addr.pointee
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(&addr!, socklen_t((interface?.ifa_addr.pointee.sa_len)!),
                                    &hostname, socklen_t(hostname.count),
                                    nil, socklen_t(0), NI_NUMERICHOST)
                        address = String(cString: hostname)
                    }
                    if address == nil {
                        if name == "pdp_ip0" {
                            var addr = interface?.ifa_addr.pointee
                            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                            getnameinfo(&addr!, socklen_t((interface?.ifa_addr.pointee.sa_len)!),
                                        &hostname, socklen_t(hostname.count),
                                        nil, socklen_t(0), NI_NUMERICHOST)
                            address = String(cString: hostname)
                        }
                    }
                    logger.debug("My network address: \(String(describing: address)) (interface \(name))")
                }
                ptr = ptr?.pointee.ifa_next
            }
            freeifaddrs(ifaddr)
        }

        return address
    }
}









