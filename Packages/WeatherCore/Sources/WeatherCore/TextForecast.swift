import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Environment Canada's written forecast for the nearest city page, as its forecasters wrote it
/// ("Rain beginning near noon. High 6.").
public struct TextForecast: Equatable, Codable, Sendable {
    public struct Period: Equatable, Codable, Sendable, Identifiable {
        public var name: String     // "Today", "Tonight", "Sunday"
        public var text: String
        public var id: String { name }
    }

    public var cityName: String
    public var periods: [Period]
}

public struct TextForecastProvider: Sendable {
    private let loader: OpenMeteoProvider.DataLoader

    public init(loader: @escaping OpenMeteoProvider.DataLoader = { try await URLSession.shared.data(for: $0) }) {
        self.loader = loader
    }

    /// nil outside Canada or when no city page is within reach.
    public func forecast(near coordinate: Coordinate) async throws -> TextForecast? {
        guard EnvironmentCanadaProvider.mightBeInCanada(coordinate) else { return nil }
        let environmentCanada = EnvironmentCanadaProvider(loader: loader)
        for span in [0.4, 1.5] {
            let request = URLRequest(url: environmentCanada.url(for: coordinate, span: span), timeoutInterval: 15)
            let (data, response) = try await loader(request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ForecastError.httpStatus(http.statusCode)
            }
            if let text = try Self.parse(data, near: coordinate) { return text }
        }
        return nil
    }

    /// The nearest city page (by its own point) that has written periods, within 50 km.
    static func parse(_ data: Data, near coordinate: Coordinate, maxDistanceKm: Double = 50) throws -> TextForecast? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else {
            throw ForecastError.missingData("features")
        }
        typealias E = EnvironmentCanadaProvider
        var best: (distance: Double, forecast: TextForecast)?
        for feature in features {
            guard let properties = feature["properties"] as? [String: Any],
                  let point = E.pointCoordinate(feature["geometry"]) else { continue }
            let distance = E.distanceKm(coordinate, point)
            guard distance <= maxDistanceKm, distance < (best?.distance ?? .infinity) else { continue }
            let group = properties["forecastGroup"] as? [String: Any]
            let items = (group?["forecasts"] as? [[String: Any]]) ?? []
            let periods: [TextForecast.Period] = items.compactMap { item in
                let period = item["period"] as? [String: Any]
                let name = (E.en(period?["textForecastName"]) as? String)
                    ?? (E.en(period?["value"]) as? String)
                    ?? (E.en(item["period"]) as? String)
                guard let name, let text = E.en(item["textSummary"]) as? String,
                      !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                return TextForecast.Period(name: name, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            guard !periods.isEmpty else { continue }
            let city = (E.en(properties["name"]) as? String) ?? "Nearby"
            best = (distance, TextForecast(cityName: city, periods: periods))
        }
        return best?.forecast
    }
}
