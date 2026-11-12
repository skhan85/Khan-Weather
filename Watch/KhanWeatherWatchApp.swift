import SwiftUI
import WeatherCore

@main
struct KhanWeatherWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchContentView()
        }
    }
}

struct WatchContentView: View {
    @StateObject private var model = WeatherViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView()
            case .failed(let message):
                VStack(spacing: 8) {
                    Text(message).font(.footnote)
                    Button("Retry") { Task { await model.refresh() } }
                }
            case .loaded(let forecast):
                ScrollView {
                    VStack(spacing: 4) {
                        if let place = model.placeName {
                            Text(place)
                                .font(.footnote.weight(.semibold))
                                .lineLimit(1)
                        }
                        ConditionIcon(condition: forecast.current.condition, isDay: forecast.current.isDay)
                            .font(.title)
                        Text(WeatherFormat.temperature(forecast.current.temperature))
                            .font(.system(size: 44, weight: .light))
                        Text(forecast.observation?.conditionText ?? forecast.current.condition.description)
                            .font(.footnote)
                        Text("Feels \(WeatherFormat.temperature(forecast.current.feelsLike))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let today = forecast.daily.first {
                            Text("H \(WeatherFormat.temperature(today.high))  L \(WeatherFormat.temperature(today.low))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if model.usingFallbackLocation {
                            Text("Location off: Toronto")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        Text("Open-Meteo.com")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 6)
                    }
                }
            }
        }
        .task { await model.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } }
        }
    }
}
