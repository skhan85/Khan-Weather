import CoreLocation
import WeatherCore

/// Turns a coordinate into a short place name ("Mississauga", "Paris") using Apple's
/// free on-device-assisted geocoder. Returns nil if the lookup fails or is offline.
enum PlaceNameResolver {
    static func name(for coordinate: Coordinate) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        return placemark.locality ?? placemark.subAdministrativeArea ?? placemark.administrativeArea ?? placemark.name
    }
}
