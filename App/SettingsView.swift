import SwiftUI
import UIKit
import UserNotifications
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
    @AppStorage(AlertNotifier.enabledKey) private var alertNotifications = false
    @AppStorage(AlertNotifier.advisoriesKey) private var alertAdvisories = false
    @AppStorage(AlertNotifier.rainKey) private var rainNotifications = false
    @AppStorage(AlertNotifier.frostKey) private var frostNotifications = false
    @AppStorage(DisplaySettings.showAirQualityKey) private var showAirQuality = true
    @State private var notificationsDenied = false
    @State private var permissionText = "Checking…"
    @State private var permissionOK = true
    @State private var testSending = false
    @State private var testMessage: String?
    @State private var locationAuthorization = BackgroundLocation.shared.authorization
    @Environment(\.scenePhase) private var scenePhase

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
                    Toggle("Severe weather alerts", isOn: $alertNotifications)
                        .onChange(of: alertNotifications) { _, on in
                            guard on else { return }
                            Task {
                                let allowed = await AlertNotifier.requestPermission()
                                notificationsDenied = !allowed
                                if allowed { AlertNotifier.schedule(); BackgroundLocation.shared.start() } else { alertNotifications = false }
                            }
                        }
                    if alertNotifications {
                        Toggle("Include advisories and statements", isOn: $alertAdvisories)
                    }
                    Toggle("Rain or snow starting soon", isOn: $rainNotifications)
                        .onChange(of: rainNotifications) { _, on in
                            guard on else { return }
                            Task {
                                let allowed = await AlertNotifier.requestPermission()
                                notificationsDenied = !allowed
                                if allowed { AlertNotifier.schedule(); BackgroundLocation.shared.start() } else { rainNotifications = false }
                            }
                        }
                    Toggle("Frost tonight", isOn: $frostNotifications)
                        .onChange(of: frostNotifications) { _, on in
                            guard on else { return }
                            Task {
                                let allowed = await AlertNotifier.requestPermission()
                                notificationsDenied = !allowed
                                if allowed { AlertNotifier.schedule(); BackgroundLocation.shared.start() } else { frostNotifications = false }
                            }
                        }
                } header: {
                    Text("Notifications")
                } footer: {
                    if notificationsDenied {
                        Text("Notifications are turned off for Khan Weather. Turn them on in the iPhone Settings app, under Notifications.")
                    } else {
                        Text("Warnings and watches from Environment Canada, the US National Weather Service and Germany's DWD, for your location and saved places. Rain, snow and frost heads-ups are for your location and only fire when most forecast models agree; rain at most once per wet spell, frost once an afternoon. Without true push (not available on a free Apple ID), these depend on iOS waking the app, so treat them as a heads-up, not an emergency alarm. The home screen widget sends its own alert notifications; change that under Edit Widget.")
                    }
                }
                Section {
                    statusRow("Notifications allowed", permissionText, ok: permissionOK)
                    statusRow("Background App Refresh", backgroundRefreshText, ok: UIApplication.shared.backgroundRefreshStatus == .available)
                    if ProcessInfo.processInfo.isLowPowerModeEnabled {
                        statusRow("Low Power Mode", "On (pauses checks)", ok: false)
                    }
                    statusRow("Location access", locationText, ok: locationAlways)
                    statusRow("Last background check", lastCheckText, ok: AlertNotifier.lastBackgroundCheck.map { -$0.timeIntervalSinceNow < 6 * 3600 } ?? false)
                    Button(testSending ? "Sending…" : "Send a test notification") {
                        testSending = true
                        testMessage = "Sent. It arrives in \(Int(AlertNotifier.testDelay)) seconds; you can lock the phone to watch for it."
                        Task {
                            let result = await AlertNotifier.sendTest()
                            await refreshPermission()
                            testSending = false
                            switch result {
                            case .delivered:
                                testMessage = "iOS delivered the test notification. If no banner or sound came, a Focus such as Sleep or Do Not Disturb is holding it: swipe down for Notification Center, and add Khan Weather to the Focus's allowed apps in Settings > Focus."
                            case .notDelivered:
                                testMessage = "iOS didn't deliver the test notification. Check Settings > Notifications > Khan Weather and make sure Allow Notifications is on."
                            case .failed(let error):
                                testMessage = "iOS refused the notification: \(error)"
                            }
                        }
                    }
                    .disabled(testSending)
                    if let testMessage {
                        Text(testMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                    if !locationAlways && locationAuthorization != .denied {
                        Button("Allow location Always") { BackgroundLocation.shared.requestAlways() }
                    }
                    if !permissionOK || !locationAlways || UIApplication.shared.backgroundRefreshStatus != .available {
                        Button("Open iPhone Settings for Khan Weather") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                } header: {
                    Text("Notification status")
                } footer: {
                    Text("Khan Weather checks when iOS wakes it: Background App Refresh, and with location set to Always, whenever you move about 500 m or arrive somewhere. The home screen widget also checks for alerts each time it refreshes. Rain and frost heads-ups are scheduled ahead whenever the app runs. Swiping the app away in the app switcher stops all of this until you open it again.")
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
                    Toggle("Air quality and pollen", isOn: $showAirQuality)
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
                    LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
                    Link("Forecast and air quality: Open-Meteo.com (CC BY 4.0)", destination: URL(string: "https://open-meteo.com/")!)
                    Link("Canada: Environment and Climate Change Canada", destination: URL(string: "https://weather.gc.ca/")!)
                    Link("US: National Weather Service", destination: URL(string: "https://www.weather.gov/")!)
                    Link("Germany: Deutscher Wetterdienst via Bright Sky", destination: URL(string: "https://brightsky.dev/")!)
                    Link("Airports: NOAA Aviation Weather Center", destination: URL(string: "https://aviationweather.gov/")!)
                    Link("Personal weather stations: Netatmo", destination: URL(string: "https://weathermap.netatmo.com/")!)
                }
            }
            .task { await refreshPermission() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await refreshPermission() } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .locationAuthorizationChanged)) { _ in
                locationAuthorization = BackgroundLocation.shared.authorization
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
    }

    private func statusRow(_ label: String, _ value: String, ok: Bool) -> some View {
        LabeledContent(label) {
            Label(value, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
        }
    }

    private var backgroundRefreshText: String {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available: return "On"
        case .denied: return "Off"
        case .restricted: return "Restricted"
        @unknown default: return "Unknown"
        }
    }

    private var lastCheckText: String {
        guard let last = AlertNotifier.lastBackgroundCheck else { return "Never yet" }
        let when = last.formatted(.relative(presentation: .named))
        return AlertNotifier.lastBackgroundReason.map { "\(when), \($0)" } ?? when
    }

    private var locationAlways: Bool { locationAuthorization == .authorizedAlways }

    private var locationText: String {
        switch locationAuthorization {
        case .authorizedAlways: return "Always"
        case .authorizedWhenInUse: return "While Using"
        case .denied: return "Off"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not asked yet"
        @unknown default: return "Unknown"
        }
    }

    private func refreshPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            let banners = settings.alertSetting == .enabled || settings.lockScreenSetting == .enabled || settings.notificationCenterSetting == .enabled
            permissionText = banners ? "Yes" : "Yes, but hidden"
            permissionOK = banners
        case .denied:
            permissionText = "No"
            permissionOK = false
        case .notDetermined:
            permissionText = "Not asked yet"
            permissionOK = false
        @unknown default:
            permissionText = "Unknown"
            permissionOK = false
        }
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
        showAirQuality = true
    }
}
