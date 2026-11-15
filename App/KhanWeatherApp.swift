import SwiftUI
import UserNotifications

@main
struct KhanWeatherApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
    }

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("-designPreview") {
                DesignPreview()
            } else {
                ContentView()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { AlertNotifier.schedule() }
            if phase == .active { Task { await AlertNotifier.ensurePermission() } }
        }
        .backgroundTask(.appRefresh(AlertNotifier.taskID)) {
            AlertNotifier.schedule()
            await AlertNotifier.checkAll()
        }
    }
}
