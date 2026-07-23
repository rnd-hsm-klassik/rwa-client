//
//  MapViewController.swift
//  rwaclient
//
//  Created by Admin on 26.09.18.
//  Copyright © 2018 beryllium design. All rights reserved.
//

import Foundation
import UIKit
import MapKit

//var annotation = AttractionAnnotation(coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),title: "UBLOX",subtitle: "", type: AttractionType.misc)
//var london = MKPointAnnotation()

extension MapViewController {
    
    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if overlay is MKCircle {
            let renderer = MKCircleRenderer(overlay: overlay)
            renderer.fillColor = UIColor.black.withAlphaComponent(0.1)
            renderer.strokeColor = UIColor.blue
            renderer.lineWidth = 2
            return renderer
            
        } else if overlay is MKPolyline {
            let renderer = MKPolylineRenderer(overlay: overlay)
            renderer.strokeColor = UIColor.orange
            renderer.lineWidth = 3
            return renderer
            
        } else if overlay is MKPolygon {
            let renderer = MKPolygonRenderer(polygon: overlay as! MKPolygon)
            renderer.fillColor = UIColor.black.withAlphaComponent(0.1)
            renderer.strokeColor = UIColor.orange
            renderer.lineWidth = 2
            return renderer
        }
        
        return MKOverlayRenderer()
    }
    
    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {

        guard !annotation.isKind(of: MKUserLocation.self) else {
                // Make a fast exit if the annotation is the `MKUserLocation`, as it's not an annotation view we wish to customize.
                return nil
            }
            
        guard annotation is MKPointAnnotation else { return nil }

            let identifier = "Annotation"
            var annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)

            if annotationView == nil {
                annotationView = MKPinAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                annotationView!.canShowCallout = true
            } else {
                annotationView!.annotation = annotation
            }
        return annotationView
       
    }
 }

extension MKMapView {
    open var currentZoomLevel: Int {
        let maxZoom: Double = 24
        let zoomScale = visibleMapRect.size.width / Double(frame.size.width)
        let zoomExponent = log2(zoomScale)
        return Int(maxZoom - ceil(zoomExponent))
    }
    
    open func setCenterCoordinate(_ centerCoordinate: CLLocationCoordinate2D,
                                  withZoomLevel zoomLevel: Int,
                                  animated: Bool) {
        let minZoomLevel = min(zoomLevel, 28)
        
        let span = coordinateSpan(centerCoordinate, andZoomLevel: minZoomLevel)
        let region = MKCoordinateRegion(center: centerCoordinate, span: span)
        
        setRegion(region, animated: animated)
    }
    
    func polygonFromRectangle(_ center:CLLocationCoordinate2D,_ width: Double,_ height: Double) -> MKPolygon
    {
        var rectCoordinates: [CLLocationCoordinate2D] = [];
        
        let w = calculateDestination(center, width/2, 90);
        let e = calculateDestination(center, width/2, 270);
        
        var nw:CLLocationCoordinate2D =  calculateDestination(w, height/2, 0) ;
        
        var sw:CLLocationCoordinate2D = (calculateDestination(w, height/2, 180) );
        if(sw.longitude < 0)
        {
            sw.longitude = sw.longitude + 360;
        }
        rectCoordinates.append(sw);
        
        if(nw.longitude < 0)
        {
            nw.longitude = nw.longitude + 360;
        }
        
        rectCoordinates.append(nw);
        
        var ne:CLLocationCoordinate2D = (calculateDestination(e, height/2, 0) );
        if(ne.longitude < 0)
        {
            ne.longitude = ne.longitude + 360;
        }
        
        rectCoordinates.append(ne);
        
        var se = (calculateDestination(e, height/2, 180) );
        if(se.longitude < 0)
        {
            se.longitude = se.longitude + 360;
        }
        
        rectCoordinates.append(se);
        let polygon = MKPolygon(coordinates: &rectCoordinates, count: rectCoordinates.count);
        return polygon;
    }
}

let MERCATOR_OFFSET: Double = 268435456 // swiftlint:disable:this identifier_name
let MERCATOR_RADIUS: Double = 85445659.44705395 // swiftlint:disable:this identifier_name
struct PixelSpace {
    public var x: Double // swiftlint:disable:this identifier_name
    public var y: Double // swiftlint:disable:this identifier_name
}

fileprivate extension MKMapView {
    func coordinateSpan(_ centerCoordinate: CLLocationCoordinate2D, andZoomLevel zoomLevel: Int) -> MKCoordinateSpan {
        let space = pixelSpace(fromLongitue: centerCoordinate.longitude, withLatitude: centerCoordinate.latitude)
        
        // determine the scale value from the zoom level
        let zoomExponent = 20 - zoomLevel
        let zoomScale = pow(2.0, Double(zoomExponent))
        
        // scale the map’s size in pixel space
        let mapSizeInPixels = self.bounds.size
        let scaledMapWidth = Double(mapSizeInPixels.width) * zoomScale
        let scaledMapHeight = Double(mapSizeInPixels.height) * zoomScale
        
        // figure out the position of the top-left pixel
        let topLeftPixelX = space.x - (scaledMapWidth / 2)
        let topLeftPixelY = space.y - (scaledMapHeight / 2)
        
        var minSpace = space
        minSpace.x = topLeftPixelX
        minSpace.y = topLeftPixelY
        
        var maxSpace = space
        maxSpace.x += scaledMapWidth
        maxSpace.y += scaledMapHeight
        
        // find delta between left and right longitudes
        let minLongitude = coordinate(fromPixelSpace: minSpace).longitude
        let maxLongitude = coordinate(fromPixelSpace: maxSpace).longitude
        let longitudeDelta = maxLongitude - minLongitude
        
        // find delta between top and bottom latitudes
        let minLatitude = coordinate(fromPixelSpace: minSpace).latitude
        let maxLatitude = coordinate(fromPixelSpace: maxSpace).latitude
        let latitudeDelta = -1 * (maxLatitude - minLatitude)
        
        return MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
    }
    
    func pixelSpace(fromLongitue longitude: Double, withLatitude latitude: Double) -> PixelSpace {
        let x = round(MERCATOR_OFFSET + MERCATOR_RADIUS * longitude * Double.pi / 180.0)
        let y = round(MERCATOR_OFFSET - MERCATOR_RADIUS * log((1 + sin(latitude * Double.pi / 180.0)) / (1 - sin(latitude * Double.pi / 180.0))) / 2.0) // swiftlint:disable:this line_length
        return PixelSpace(x: x, y: y)
    }
    
    func coordinate(fromPixelSpace pixelSpace: PixelSpace) -> CLLocationCoordinate2D {
        let longitude = ((round(pixelSpace.x) - MERCATOR_OFFSET) / MERCATOR_RADIUS) * 180.0 / Double.pi
        let latitude = (Double.pi / 2.0 - 2.0 * atan(exp((round(pixelSpace.y) - MERCATOR_OFFSET) / MERCATOR_RADIUS))) * 180.0 / Double.pi // swiftlint:disable:this line_length
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

class MapViewController: UIViewController, MKMapViewDelegate
{
    @IBOutlet var mapView: MKMapView!
    @IBOutlet var currentScene: UITextField!
    @IBOutlet var currentState: UITextField!
    
    @objc func redraw() {
        let overlays = mapView.overlays
        mapView.removeOverlays(overlays)
        let annotations = mapView.annotations
        mapView.removeAnnotations(annotations)
        if let scene = hero.currentScene {
            drawScene(scene)
        }
        mapView.setNeedsDisplay();
        print("REDRAW MAP")
    }
    
    @objc func updateScene() {
        if let scene = hero.currentScene {
            let sceneName = scene.name
            currentScene.text = sceneName
        }
        updateState()
    }
    
    @objc func updateState() {
        if let state = hero.currentState {
            let stateName = state.stateName
            currentState.text = stateName
        }
        else {
            currentState.text = ""
        }
        
    }
    
    /// The scene/state fields are read-only status displays over the map:
    /// scene and state are driven by GPS, so there is nothing to edit here.
    /// Adaptive system colors keep them legible in light and dark mode.
    private func styleStatusField(_ field: UITextField) {
        field.isUserInteractionEnabled = false  // no keyboard, taps reach the map
        field.borderStyle = .none
        field.layer.cornerRadius = 8
        field.layer.masksToBounds = true
        field.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.85)
        field.textColor = .label
        field.textAlignment = .center
        field.font = UIFont.preferredFont(forTextStyle: .subheadline)
    }

    /// Lays out the two status fields in code, replacing the storyboard's
    /// constraints: those anchored the fields to the deprecated
    /// topLayoutGuide and — presumably by accident — made their width
    /// proportional to the superview's *height*, which oversized them on
    /// tall devices. Two equal-width pills sharing the top of the map.
    private func layoutStatusFields() {
        let obsolete = view.constraints.filter {
            $0.firstItem === currentScene || $0.secondItem === currentScene ||
            $0.firstItem === currentState || $0.secondItem === currentState
        }
        NSLayoutConstraint.deactivate(obsolete)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            currentScene.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            currentScene.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            currentState.topAnchor.constraint(equalTo: currentScene.topAnchor),
            currentState.leadingAnchor.constraint(equalTo: currentScene.trailingAnchor, constant: 8),
            currentState.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            currentState.widthAnchor.constraint(equalTo: currentScene.widthAnchor)
        ])
    }

    override func viewDidLoad() {

        NotificationCenter.default.addObserver(self, selector: #selector(self.redraw), name: NSNotification.Name(rawValue: "Redraw Map"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.updateScene), name: NSNotification.Name(rawValue: "Update Scene"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.updateState), name: NSNotification.Name(rawValue: "Update State"), object: nil)
        super.viewDidLoad()
        mapView.delegate = self
        styleStatusField(currentScene)
        styleStatusField(currentState)
        layoutStatusFields()
        if(scenes.isEmpty) {
            mapView.setCenterCoordinate(hero.coordinates, withZoomLevel: 15, animated: true);
          }
        else {
            mapView.setCenterCoordinate(scenes[0].coordinates, withZoomLevel: 15, animated: true);
        }
        
        mapView.showsScale = true;
        mapView.showsUserLocation = true;
        mapView.showAnnotations(mapView.annotations, animated: true)
        updateScene()
    }
    
    func drawRwaArea(area: RwaArea) {
        
        if(area.areaType == RWAAREATYPE_POLYGON) {
            let polygon = MKPolygon(coordinates: &area.corners!, count: (area.corners?.count)!);
            mapView.add(polygon);
        }
        
        if(area.areaType == RWAAREATYPE_RECTANGLE || area.areaType == RWAAREATYPE_SQUARE) {
            
            let polygon = mapView.polygonFromRectangle(area.coordinates, area.width, area.height)
            mapView.add(polygon);
        }
        
        if(area.areaType == RWAAREATYPE_CIRCLE) {
            
            let circle = MKCircle(center: area.coordinates, radius: area.radius);
            mapView.add(circle);
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        redraw()
    }
    
    fileprivate func drawScene(_ scene: RwaScene) {
        drawRwaArea(area: scene);
        
        for state in scene.states {
            
            if(state.type != RWASTATETYPE_FALLBACK && state.type != RWASTATETYPE_BACKGROUND) {
                drawRwaArea(area: state);
                //                            let coordinate = CLLocationCoordinate2D(latitude: state.coordinates.latitude, longitude: state.coordinates.longitude)
                //                            let london = MKPointAnnotation()
                //                            london.title = ""
                //                            london.coordinate = coordinate
                //                            mapView.addAnnotation(london)
            }
            for asset in state.assets {
                let coordinate = CLLocationCoordinate2D(latitude: asset.coordinates.latitude, longitude: asset.coordinates.longitude)
                let annotation = AttractionAnnotation(coordinate: coordinate,
                                                      title: asset.name,
                                                      subtitle: "",
                                                      type: AttractionType.misc)
                mapView.addAnnotation(annotation)
            }
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        
        super.viewDidLoad();
        
        if scenes.isEmpty {
            return;
        }
        
        if (!rwagameloop.isRunning)        {
            drawScene(scenes[0])
            return
        }

        for scene in scenes
        {
            if scene == hero.currentScene {
                drawScene(scene)
            }
        }
     }
 }

enum AttractionType: Int {
  case misc = 0
  case ride
  case food
  case firstAid
  
  func image() -> UIImage {
    switch self {
    case .misc:
      return UIImage(imageLiteralResourceName: "star")
    case .ride:
      return UIImage(imageLiteralResourceName: "ride")
    case .food:
      return UIImage(imageLiteralResourceName: "food")
    case .firstAid:
      return UIImage(imageLiteralResourceName: "firstaid")
    }
  }
}

// 2
class AttractionAnnotation: NSObject, MKAnnotation
{
  let coordinate: CLLocationCoordinate2D
  let title: String?
  let subtitle: String?
  let type: AttractionType
  
  init(coordinate: CLLocationCoordinate2D, title: String, subtitle: String, type: AttractionType)
  {
    self.coordinate = coordinate
    self.title = title
    self.subtitle = subtitle
    self.type = type
  }
}

class AttractionAnnotationView: MKAnnotationView {
  // 1
  // Required for MKAnnotationView
  required init?(coder aDecoder: NSCoder) {
    super.init(coder: aDecoder)
  }
  
  // 2
  override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
    super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
    guard
      let attractionAnnotation = self.annotation as? AttractionAnnotation else {
        return
    }
    
    image = attractionAnnotation.type.image()
  }
}
