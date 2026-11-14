import SwiftUI
import WeatherCore

/// "💧 40%" or "❄ 40%": a chance of precipitation that says what it's a chance of.
struct PrecipChance: View {
    let probability: Double?
    let kind: PrecipitationKind
    var font: Font = .caption
    var showsIcon = true
    @Environment(\.colorScheme) private var colorScheme

    /// Brighter blues on the dark sky screens so the number stays readable.
    private var colour: Color {
        if colorScheme == .dark {
            return kind == .snow ? Color(red: 0.75, green: 0.92, blue: 1) : Color(red: 0.52, green: 0.80, blue: 1)
        }
        return kind == .snow ? .cyan : .blue
    }

    var body: some View {
        if let probability, probability >= 10 {
            HStack(spacing: 2) {
                if showsIcon {
                    Image(systemName: kind.symbolName)
                        .imageScale(.small)
                }
                Text(WeatherFormat.percent(probability))
            }
            .font(font)
            .foregroundStyle(colour)
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
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Brand.gold)
                    .frame(width: 28)
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 8)
                Text(value)
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
        }
    }
}

/// The big card at the top of the hour and day screens, in the same style as the main Now card.
struct DetailHero: View {
    let tag: String
    let condition: WeatherCondition
    var isDay = true
    let temperature: String
    let headline: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tag.uppercased())
                .font(.caption.weight(.heavy))
                .tracking(1.2)
                .foregroundStyle(.black.opacity(0.8))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Brand.gold))
            HStack(spacing: 16) {
                IconBadge(condition: condition, isDay: isDay, size: 88)
                VStack(alignment: .leading, spacing: 2) {
                    Text(temperature)
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(headline)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail)
                            .font(.headline)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .fontDesign(.rounded)
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.06)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(.white.opacity(0.3), lineWidth: 1))
        }
        .padding(.horizontal, 16)
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
                DetailHero(tag: hour.time.formatted(Date.FormatStyle(timeZone: timeZone).weekday(.wide).hour()),
                           condition: hour.condition, isDay: hour.isDay,
                           temperature: WeatherFormat.temperature(hour.temperature),
                           headline: hour.condition.description,
                           detail: hour.feelsLike.map { "Feels like \(WeatherFormat.temperature($0))" })
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            .listRowBackground(Color.clear)
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
            } header: {
                SkySectionHeader(title: "Details", systemImage: "list.bullet")
            }
            .glassRow()
        }
        .fontDesign(.rounded)
        .skyBackground(hour.condition, isDay: hour.isDay)
        .navigationTitle(hour.time.formatted(Date.FormatStyle(timeZone: timeZone).weekday(.wide).hour()))
        .skyTitle(hour.time.formatted(Date.FormatStyle(timeZone: timeZone).weekday(.wide).hour()))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DayDetailView: View {
    let day: DailyForecast
    let hours: [HourlyForecast]
    let timeZone: TimeZone
    var location: Coordinate?

    var body: some View {
        List {
            Section {
                DetailHero(tag: day.date.formatted(Date.FormatStyle(timeZone: timeZone).weekday(.wide)),
                           condition: day.condition,
                           temperature: "\(WeatherFormat.temperature(day.high)) / \(WeatherFormat.temperature(day.low))",
                           headline: day.summary ?? day.condition.description,
                           detail: day.feelsLikeHigh.flatMap { hi in day.feelsLikeLow.map { lo in
                               "Feels like \(WeatherFormat.temperature(hi)) / \(WeatherFormat.temperature(lo))" } })
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            .listRowBackground(Color.clear)
            if !hours.isEmpty {
                Section {
                    HourlyCurve(hours: hours, timeZone: timeZone, firstIsNow: false)
                } header: {
                    SkySectionHeader(title: "Hour by hour", systemImage: "clock")
                }
                .glassRow()
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
            } header: {
                SkySectionHeader(title: "Details", systemImage: "list.bullet")
            }
            .glassRow()
            if let location {
                Section {
                    NavigationLink {
                        ModelComparisonView(day: day, location: location, timeZone: timeZone)
                    } label: {
                        Label {
                            Text("Compare forecast models").font(.body.weight(.semibold))
                        } icon: {
                            Image(systemName: "chart.bar.xaxis").foregroundStyle(Brand.gold)
                        }
                    }
                }
                .glassRow()
            }
        }
        .fontDesign(.rounded)
        .skyBackground(day.condition, isDay: true)
        .navigationTitle(day.date.formatted(Date.FormatStyle(timeZone: timeZone).weekday(.wide).month().day()))
        .skyTitle(day.date.formatted(Date.FormatStyle(timeZone: timeZone).weekday(.wide).month().day()))
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
                if forecast.observation?.dataProvider == "ON-MTO" || forecast.observation?.skyDataProvider == "ON-MTO" {
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
        observation(provider: o.dataProvider)
    }

    private static func observation(provider: String?) -> (String, Credit) {
        switch provider {
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
        if let o = forecast.observation {
            list.append(observation(o))
            // Netatmo gives the temperature; rain, snow and cloud still come from an official station.
            if o.dataProvider == "NETATMO", o.skyStationName != nil {
                let (name, credit) = observation(provider: o.skyDataProvider)
                list.append((name, Credit(text: credit.text.replacingOccurrences(of: "Observations", with: "Sky")
                                                     .replacingOccurrences(of: "Airport observations", with: "Sky"),
                                          url: credit.url)))
            }
        }
        if forecast.radar != nil {
            list.append(("Environment Canada", Credit(text: "Radar: Environment and Climate Change Canada", url: URL(string: "https://weather.gc.ca/")!)))
        }
        for source in Set(alerts.map(\.source)).sorted() { list.append(alertCredit(source)) }
        return list
    }

    static func shortNames(forecast: Forecast, alerts: [WeatherAlert]) -> [String] {
        var names = ["Open-Meteo"]
        for (name, _) in all(forecast: forecast, alerts: alerts) where !names.contains(name) { names.append(name) }
        if forecast.observation?.dataProvider == "ON-MTO" || forecast.observation?.skyDataProvider == "ON-MTO" { names.append("Ontario MTO") }
        return names
    }

    static func full(forecast: Forecast, alerts: [WeatherAlert]) -> [Credit] {
        all(forecast: forecast, alerts: alerts).map(\.1)
    }
}
