import SwiftUI
import UserNotifications

@main
struct KhanWeatherApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
        BackgroundLocation.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("-designPreview") {
                DesignPreview()
            } else if ProcessInfo.processInfo.arguments.contains("-radarScreen") {
                // CI screenshots of the radar card and the full radar map.
                RadarScreenPreview()
            } else {
                ContentView()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { AlertNotifier.schedule() }
            if phase == .active {
                BackgroundLocation.shared.start()
                Task {
                    await AlertNotifier.ensurePermission()
                    // Plan rain and frost heads-ups ahead while the app is open anyway.
                    await AlertNotifier.checkForecast(foreground: true)
                }
            }
        }
        .backgroundTask(.appRefresh(AlertNotifier.taskID)) {
            AlertNotifier.schedule()
            await AlertNotifier.checkAll()
        }
    }
}
