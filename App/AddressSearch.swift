import CoreLocation
import WeatherCore

/// Postal codes, zip codes and street addresses via Apple's geocoder (free, built into iOS).
/// Open-Meteo's place search only knows town names, so anything with a digit goes here first.
enum AddressSearch {
    static func looksLikeCode(_ query: String) -> Bool {
        query.contains { $0.isNumber }
    }

    static func search(_ query: String) async -> [SavedPlace] {
        guard let marks = try? await CLGeocoder().geocodeAddressString(query) else { return [] }
        return marks.compactMap { mark -> SavedPlace? in
            guard let location = mark.location else { return nil }
            let town = mark.locality ?? mark.subAdministrativeArea ?? mark.name ?? query
            let name = [town, mark.postalCode].compactMap { $0 }.joined(separator: " ")
            let detail = [mark.administrativeArea, mark.country].compactMap { $0 }.joined(separator: ", ")
            return SavedPlace(name: name, detail: detail.isEmpty ? nil : detail,
                              coordinate: Coordinate(latitude: location.coordinate.latitude,
                                                     longitude: location.coordinate.longitude))
        }
    }
}
