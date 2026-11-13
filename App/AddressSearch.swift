import CoreLocation
import WeatherCore

/// Postal codes, zip codes and street addresses via Apple's geocoder (free, built into iOS).
/// Open-Meteo's place search only knows town names, so anything with a digit goes here first.
enum AddressSearch {
    static func looksLikeCode(_ query: String) -> Bool {
        query.contains { $0.isNumber }
    }

    /// True when the query had a longer code than the place Apple found, e.g. "L9E 1W5" → "L9E".
    static func isPartialMatch(query: String, postal: String) -> Bool {
        func alnum(_ s: String) -> String { s.filter { $0.isLetter || $0.isNumber }.uppercased() }
        let q = alnum(query), p = alnum(postal)
        return !p.isEmpty && q.count > p.count && q.hasPrefix(p)
    }

    static func search(_ query: String) async -> [SavedPlace] {
        guard let marks = try? await CLGeocoder().geocodeAddressString(query) else { return [] }
        return marks.compactMap { mark -> SavedPlace? in
            guard let location = mark.location else { return nil }
            let town = mark.locality ?? mark.subAdministrativeArea ?? mark.name ?? query
            var name = [town, mark.postalCode].compactMap { $0 }.joined(separator: " ")
            var detail = [mark.administrativeArea, mark.country].compactMap { $0 }.joined(separator: ", ")
            // Apple often knows only the first half of a Canadian postal code ("L9E" for "L9E 1W5")
            // and returns the middle of that whole area, which can be several km from the address.
            if let postal = mark.postalCode, isPartialMatch(query: query, postal: postal) {
                name = "\(town) (\(postal) area)"
                detail = "Middle of the \(postal) area, not the exact spot. Type a street address for an exact spot."
            }
            return SavedPlace(name: name, detail: detail.isEmpty ? nil : detail,
                              coordinate: Coordinate(latitude: location.coordinate.latitude,
                                                     longitude: location.coordinate.longitude))
        }
    }
}
