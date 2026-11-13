import SwiftUI

@main
struct KhanWeatherApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { AlertNotifier.schedule() }
        }
        .backgroundTask(.appRefresh(AlertNotifier.taskID)) {
            AlertNotifier.schedule()
            await AlertNotifier.check()
        }
    }
}
