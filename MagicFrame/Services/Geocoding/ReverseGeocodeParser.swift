import CoreLocation
import Foundation
import MapKit

/// Extracts city, state, and place labels from `MKMapItem` reverse-geocode results.
enum ReverseGeocodeParser {

    private static func optionalString(on object: NSObject, key: String) -> String? {
        guard let raw = object.value(forKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Avoids referencing `MKAddressRepresentations` (iOS 26+) in the type signature.
    private static func mapItemAddressRepresentations(_ mapItem: MKMapItem) -> NSObject? {
        (mapItem as NSObject).value(forKey: "addressRepresentations") as? NSObject
    }

    /// Avoids referencing `MKAddress` (iOS 26+) in the type signature.
    private static func mapItemAddress(_ mapItem: MKMapItem) -> NSObject? {
        (mapItem as NSObject).value(forKey: "address") as? NSObject
    }

    static func geocodedCity(from mapItem: MKMapItem) -> String? {
        guard let reps = mapItemAddressRepresentations(mapItem) else { return nil }
        return optionalString(on: reps, key: "cityName")
    }

    static func geocodedCityWithContext(from mapItem: MKMapItem) -> String? {
        guard let reps = mapItemAddressRepresentations(mapItem) else { return nil }
        return optionalString(on: reps, key: "cityWithContext")
    }

    static func administrativeArea(from mapItem: MKMapItem) -> String? {
        guard let context = geocodedCityWithContext(from: mapItem) else { return nil }
        let parts = context
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        return parts[1]
    }

    /// Safe coordinate lookup — `MKMapItem.location` and `.placemark` can be nil at runtime on iOS 26.
    static func coordinate(from mapItem: MKMapItem) -> CLLocationCoordinate2D? {
        if let location = (mapItem as NSObject).value(forKey: "location") as? CLLocation {
            return location.coordinate
        }

        if let placemark = (mapItem as NSObject).value(forKey: "placemark") as? MKPlacemark,
           let coordinate = placemark.location?.coordinate {
            return coordinate
        }

        return nil
    }

    static func placeLabel(from mapItem: MKMapItem) -> String? {
        let city = geocodedCity(from: mapItem)
        let state = administrativeArea(from: mapItem)
        let cityWithContext = geocodedCityWithContext(from: mapItem)

        if let name = mapItem.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty,
           name != city,
           name != state,
           name != cityWithContext {
            return name
        }

        if let address = mapItemAddress(mapItem),
           let shortAddress = optionalString(on: address, key: "shortAddress"),
           shortAddress != city,
           shortAddress != cityWithContext {
            return shortAddress
        }

        return nil
    }

    static func geocodedFormattedAddress(from mapItem: MKMapItem) -> String {
        if let placeName = placeLabel(from: mapItem) {
            if let city = geocodedCity(from: mapItem),
               let state = administrativeArea(from: mapItem) {
                return "\(placeName), \(city), \(state)"
            }
            return placeName
        }

        if #available(iOS 26.0, *),
           let reps = mapItemAddressRepresentations(mapItem) as? MKAddressRepresentations,
           let fullAddress = reps.fullAddress(includingRegion: false, singleLine: true),
           !fullAddress.isEmpty {
            return fullAddress
        }

        if let address = mapItemAddress(mapItem),
           let fullAddress = optionalString(on: address, key: "fullAddress") {
            return fullAddress
        }

        return ""
    }
}
