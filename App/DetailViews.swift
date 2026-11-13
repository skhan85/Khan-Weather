import SwiftUI
import WeatherCore

/// "💧 40%" or "❄ 40%": a chance of precipitation that says what it's a chance of.
struct PrecipChance: View {
    let probability: Double?
    let kind: PrecipitationKind
    var font: Font = .caption

    var body: some View {
        if let probability, probability >= 10 {
            HStack(spacing: 2) {
                Image(systemName: kind.symbolName)
                    .imageScale(.small)
                Text(WeatherFormat.percent(probability))
            }
            .font(font)
            .foregroundStyle(kind == .snow ? Color.cyan : Color.blue)
            .accessibilityLabel("\(WeatherFormat.percent(probability)) chance of \(kind.noun)")
        }
    }
}

/// One labelled value in a detail list.
private struct DetailRow: View {
    let title: String
    let value: String?
    let systemImage: String

    var body: some View {
        if let value {
            LabeledContent {
                Text(value)
            } label: {
                Label(title, systemImage: systemImage)
            }
        }
    }
}

private func chanceText(_ p: Double?, _ kind: PrecipitationKind) -> String? {
    guard let p else { return nil }
    return "\(WeatherFormat.percent(p)) chance of \(kind.noun)"
}

private func windText(_ speed: Double?, gusts: Double?, direction: Double?) -> String? {
    guard let speed else { return nil }
    var text = WeatherFormat.wind(speed)
    if let dir = WeatherFormat.compass(direction) { text = "\(dir) \(text)" }
    if let gusts, gusts >= speed + 10 { text += ", gusts \(WeatherFormat.wind(gusts))" }
    return text
}

private func visibilityText(_ metres: Double?) -> String? {
    metres.flatMap { WeatherFormat.distance($0 / 1000) }
}

struct HourDetailView: View {
    let hour: HourlyForecast
    let timeZone: TimeZone

    var body: some View {
        List {
            Section {
                VStack(spacing: 6) {
                    ConditionIcon(condition: hour.condition, isDay: hour.isDay)
                        .font(.system(size: 44))
                    Text(WeatherFormat.temperature(hour.temperature))
                        .font(.system(size: 48, weight: .thin))
                    Text(hour.condition.description)
                        .font(.title3)
                    if let feels = hour.feelsLike {
                        Text("Feels like \(WeatherFormat.temperature(feels))")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section {
                DetailRow(title: "Precipitation", value: chanceText(hour.precipitationProbability, hour.precipitationKind),
                          systemImage: hour.precipitationKind.symbolName)
                DetailRow(title: "Amount", value: WeatherFormat.precipitationTotals(rainMm: hour.rain, snowCm: hour.snowfall),
                          systemImage: "drop.triangle")
                DetailRow(title: "Wind", value: windText(hour.windSpeed, gusts: hour.windGusts, direction: hour.windDirection),
                          systemImage: "wind")
                DetailRow(title: "Humidity", value: hour.humidity.map { WeatherFormat.percent($0) }, systemImage: "humidity")
                DetailRow(title: "Dew point", value: hour.dewPoint.map { WeatherFormat.temperature($0) },
                          systemImage: "thermometer.medium")
                DetailRow(title: "UV index", value: WeatherFormat.uvLevel(hour.uvIndex), systemImage: "sun.max")
                DetailRow(title: "Visibility", value: visibilityText(hour.visibility), systemImage: "eye")
            }
        }
        .navigationTitle(hour.time.formatted(Date.FormatStyle(timeZone: timeZone).weekday(.wide).hour()))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DayDetailView: View {
    let day: DailyForecast
    let hours: [HourlyForecast]
    let timeZone: TimeZone

    var body: some View {
        List {
            Section {
                VStack(spacing: 6) {
                    ConditionIcon(condition: day.condition)
                        .font(.system(size: 44))
                    Text("\(WeatherFormat.temperature(day.high)) / \(WeatherFormat.temperature(day.low))")
                        .font(.system(size: 40, weight: .thin))
                    Text(day.condition.description)
                        .font(.title3)
                    if let hi = day.feelsLikeHigh, let lo = day.feelsLikeLow {
                        Text("Feels like \(WeatherFormat.temperature(hi)) / \(WeatherFormat.temperature(lo))")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section {
                DetailRow(title: "Precipitation", value: chanceText(day.precipitationProbability, day.precipitationKind),
                          systemImage: day.precipitationKind.symbolName)
                DetailRow(title: "Total", value: WeatherFormat.precipitationTotals(rainMm: day.rainSum, snowCm: day.snowfallSum),
                          systemImage: "drop.triangle")
                DetailRow(title: "Hours of precipitation",
                          value: day.precipitationHours.flatMap { $0 > 0 ? "\(Int($0.rounded())) h" : nil },
                          systemImage: "clock")
                DetailRow(title: "Wind", value: windText(day.windSpeedMax, gusts: day.windGustsMax, direction: day.windDirectionDominant),
                          systemImage: "wind")
                DetailRow(title: "UV index", value: WeatherFormat.uvLevel(day.uvIndexMax), systemImage: "sun.max")
                DetailRow(title: "Sunrise", value: day.sunrise.map { TimeText.time($0, timeZone) },
                          systemImage: "sunrise")
                DetailRow(title: "Sunset", value: day.sunset.map { TimeText.time($0, timeZone) },
                          systemImage: "sunset")
            }
            if !hours.isEmpty {
                Section("Hour by hour") {
                    ForEach(hours) { hour in
                        NavigationLink {
                            HourDetailView(hour: hour, timeZone: timeZone)
                        } label: {
                            HStack {
                                Text(TimeText.hour(hour.time, timeZone))
                                    .frame(width: 56, alignment: .leading)
                                ConditionIcon(condition: hour.condition, isDay: hour.isDay)
                                    .frame(width: 28)
                                PrecipChance(probability: hour.precipitationProbability, kind: hour.precipitationKind)
                                Spacer()
                                Text(WeatherFormat.temperature(hour.temperature))
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(day.date.formatted(Date.FormatStyle(timeZone: timeZone).weekday(.wide).month().day()))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Full credits, one tap away from the main screen.
struct SourcesView: View {
    let forecast: Forecast
    let alerts: [WeatherAlert]
    let isSavedPlace: Bool

    var body: some View {
        List {
            Section {
                Link("Forecast: Open-Meteo.com (CC BY 4.0)", destination: URL(string: "https://open-meteo.com/")!)
                ForEach(Credits.full(forecast: forecast, alerts: alerts), id: \.text) { credit in
                    Link(credit.text, destination: credit.url)
                }
                if forecast.observation?.dataProvider == "ON-MTO" {
                    Text("Road weather station: Ontario Ministry of Transportation")
                }
                if isSavedPlace {
                    Link("Place search: Open-Meteo and GeoNames (CC BY 4.0), Apple Maps",
                         destination: URL(string: "https://www.geonames.org/")!)
                }
            } footer: {
                Text("Updated \(forecast.fetchedAt.formatted(date: .omitted, time: .shortened))")
            }
            if let o = forecast.observation {
                Section("Right now") {
                    LabeledContent("Station", value: o.stationName)
                    if let d = WeatherFormat.distance(o.distanceKm) { LabeledContent("Distance", value: d) }
                    LabeledContent("Observed", value: o.observedAt.formatted(Date.FormatStyle(time: .shortened, timeZone: forecast.timeZone)))
                    if let sky = o.skyStationName { LabeledContent("Sky from", value: sky) }
                    if let radar = forecast.radar {
                        LabeledContent("Radar scan", value: radar.time.formatted(Date.FormatStyle(time: .shortened, timeZone: forecast.timeZone)))
                    }
                }
            }
        }
        .navigationTitle("Sources")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Who supplied what, for the one-line credit and the full Sources page.
enum Credits {
    struct Credit { let text: String; let url: URL }

    private static func observation(_ o: Observation) -> (String, Credit) {
        switch o.dataProvider {
        case "NWS": return ("US National Weather Service",
                            Credit(text: "Observations: US National Weather Service", url: URL(string: "https://www.weather.gov/")!))
        case "DWD": return ("Deutscher Wetterdienst",
                            Credit(text: "Observations: Deutscher Wetterdienst via Bright Sky", url: URL(string: "https://brightsky.dev/")!))
        case "NETATMO": return ("Netatmo",
                                Credit(text: "Temperature: nearby Netatmo personal weather stations", url: URL(string: "https://weathermap.netatmo.com/")!))
        case "METAR": return ("NOAA Aviation Weather",
                              Credit(text: "Airport observations: NOAA Aviation Weather Center", url: URL(string: "https://aviationweather.gov/")!))
        default: return ("Environment Canada",
                         Credit(text: "Observations: Environment and Climate Change Canada", url: URL(string: "https://weather.gc.ca/")!))
        }
    }

    private static func alertCredit(_ source: String) -> (String, Credit) {
        switch source {
        case "US National Weather Service":
            return (source, Credit(text: "Alerts: US National Weather Service", url: URL(string: "https://alerts.weather.gov/")!))
        case "Deutscher Wetterdienst":
            return (source, Credit(text: "Alerts: Deutscher Wetterdienst via Bright Sky", url: URL(string: "https://www.dwd.de/")!))
        default:
            return ("Environment Canada", Credit(text: "Alerts: Environment and Climate Change Canada", url: URL(string: "https://weather.gc.ca/")!))
        }
    }

    private static func all(forecast: Forecast, alerts: [WeatherAlert]) -> [(String, Credit)] {
        var list: [(String, Credit)] = []
        if let o = forecast.observation { list.append(observation(o)) }
        if forecast.radar != nil {
            list.append(("Environment Canada", Credit(text: "Radar: Environment and Climate Change Canada", url: URL(string: "https://weather.gc.ca/")!)))
        }
        for source in Set(alerts.map(\.source)).sorted() { list.append(alertCredit(source)) }
        return list
    }

    static func shortNames(forecast: Forecast, alerts: [WeatherAlert]) -> [String] {
        var names = ["Open-Meteo"]
        for (name, _) in all(forecast: forecast, alerts: alerts) where !names.contains(name) { names.append(name) }
        if forecast.observation?.dataProvider == "ON-MTO" { names.append("Ontario MTO") }
        return names
    }

    static func full(forecast: Forecast, alerts: [WeatherAlert]) -> [Credit] {
        all(forecast: forecast, alerts: alerts).map(\.1)
    }
}
