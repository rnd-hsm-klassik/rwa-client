//
//  RwaArea.swift
//  rwaclient
//
//  Created by Admin on 12.08.18.
//  Copyright © 2018 beryllium design. All rights reserved.
//

import Foundation
import CoreLocation

let RWAAREATYPE_CIRCLE  = 1
let RWAAREATYPE_RECTANGLE = 2
let RWAAREATYPE_SQUARE = 3
let RWAAREATYPE_POLYGON = 4

let RWAAREAOFFSETTYPE_ENTER = 1
let RWAAREAOFFSETTYPE_EXIT = 2

class RwaArea:RwaLocation {
    
    var areaType: Int = 0
    
    var enterOffset: Double = -2
    var exitOffset: Double = 0
    var radius:Double = 0
    var width: Double = 0
    var height: Double = 0
    var timeOut: Double = 0
    var minStayTime: Double = 0
    
    var corners: [CLLocationCoordinate2D]? = []
    var enterOffsetCorners: [CLLocationCoordinate2D]? = []
    var exitOffsetCorners: [CLLocationCoordinate2D]? = []
}
