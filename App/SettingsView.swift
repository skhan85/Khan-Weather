import SwiftUI
import WeatherCore

/// Units. Stored in UserDefaults; WeatherFormat reads them when it draws.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(UnitSettings.temperatureKey) private var temperature = TemperatureUnit.celsius.rawValue
    @AppStorage(UnitSettings.windKey) private var wind = WindUnit.kmh.rawValue
    @AppStorage(UnitSettings.precipitationKey) private var precipitation = PrecipitationUnit.metric.rawValue

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
                Section("Wind speed") {
                    Picker("Wind speed", selection: $wind) {
                        ForEach(WindUnit.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Rain and snow amounts") {
                    Picker("Rain and snow", selection: $precipitation) {
                        ForEach(PrecipitationUnit.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    Link("Forecast: Open-Meteo.com (CC BY 4.0)", destination: URL(string: "https://open-meteo.com/")!)
                    Link("Observations and alerts: Environment and Climate Change Canada", destination: URL(string: "https://weather.gc.ca/")!)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
