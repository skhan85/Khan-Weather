import SwiftUI
import WeatherCore

/// Units and display choices. Stored in UserDefaults; the views read them when they draw.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(UnitSettings.temperatureKey) private var temperature = TemperatureUnit.celsius.rawValue
    @AppStorage(UnitSettings.windKey) private var wind = WindUnit.kmh.rawValue
    @AppStorage(UnitSettings.precipitationKey) private var precipitation = PrecipitationUnit.metric.rawValue
    @AppStorage(UnitSettings.pressureKey) private var pressure = PressureUnit.kPa.rawValue
    @AppStorage(UnitSettings.distanceKey) private var distance = DistanceUnit.km.rawValue
    @AppStorage(DisplaySettings.appearanceKey) private var appearance = Appearance.system.rawValue
    @AppStorage(DisplaySettings.clockKey) private var clock = ClockStyle.automatic.rawValue
    @AppStorage(DisplaySettings.mainTemperatureKey) private var mainTemperature = MainTemperature.actual.rawValue
    @AppStorage(DisplaySettings.hourlyCountKey) private var hourlyCount = 24
    @AppStorage(DisplaySettings.showDetailsKey) private var showDetails = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Temperature", selection: $temperature) {
                        ForEach(TemperatureUnit.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Temperature")
                } footer: {
                    Text("Home screen widgets have their own unit setting: touch and hold the widget, then Edit Widget.")
                }
                Section("Units") {
                    Picker("Wind", selection: $wind) {
                        ForEach(WindUnit.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                    Picker("Rain and snow", selection: $precipitation) {
                        ForEach(PrecipitationUnit.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                    Picker("Pressure", selection: $pressure) {
                        ForEach(PressureUnit.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                    Picker("Distance and visibility", selection: $distance) {
                        ForEach(DistanceUnit.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                }
                Section {
                    Picker("Big number shows", selection: $mainTemperature) {
                        ForEach(MainTemperature.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                    Picker("Hourly forecast", selection: $hourlyCount) {
                        Text("24 hours").tag(24)
                        Text("48 hours").tag(48)
                    }
                    Toggle("Today's details", isOn: $showDetails)
                } header: {
                    Text("Main screen")
                } footer: {
                    Text("Today's details shows pressure, UV, visibility, dew point, gusts, sunrise and sunset under the current conditions.")
                }
                Section("Display") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                    Picker("Time format", selection: $clock) {
                        ForEach(ClockStyle.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                }
                Section {
                    Button("Reset to defaults", role: .destructive, action: reset)
                }
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    Link("Forecast: Open-Meteo.com (CC BY 4.0)", destination: URL(string: "https://open-meteo.com/")!)
                    Link("Canada: Environment and Climate Change Canada", destination: URL(string: "https://weather.gc.ca/")!)
                    Link("US: National Weather Service", destination: URL(string: "https://www.weather.gov/")!)
                    Link("Germany: Deutscher Wetterdienst via Bright Sky", destination: URL(string: "https://brightsky.dev/")!)
                    Link("Airports: NOAA Aviation Weather Center", destination: URL(string: "https://aviationweather.gov/")!)
                    Link("Personal weather stations: Netatmo", destination: URL(string: "https://weathermap.netatmo.com/")!)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
    }

    private func reset() {
        temperature = TemperatureUnit.celsius.rawValue
        wind = WindUnit.kmh.rawValue
        precipitation = PrecipitationUnit.metric.rawValue
        pressure = PressureUnit.kPa.rawValue
        distance = DistanceUnit.km.rawValue
        appearance = Appearance.system.rawValue
        clock = ClockStyle.automatic.rawValue
        mainTemperature = MainTemperature.actual.rawValue
        hourlyCount = 24
        showDetails = true
    }
}
