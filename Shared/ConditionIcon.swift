import SwiftUI
import WeatherCore

/// Weather symbol with a tint per condition. Multicolor SF Symbols draw clouds in white,
/// which disappears on light backgrounds, so only clear skies use multicolor.
struct ConditionIcon: View {
    let condition: WeatherCondition
    var isDay: Bool = true

    var body: some View {
        let image = Image(systemName: condition.symbolName(isDay: isDay))
        if condition == .clear && isDay {
            image.symbolRenderingMode(.multicolor)
        } else {
            image.symbolRenderingMode(.hierarchical).foregroundStyle(tint)
        }
    }

    private var tint: Color {
        switch condition {
        case .clear: return .indigo
        case .mainlyClear, .partlyCloudy: return isDay ? .orange : .indigo
        case .overcast, .fog, .unknown: return .gray
        case .drizzle, .rain, .rainShowers: return .blue
        case .freezingDrizzle, .freezingRain: return .teal
        case .snow, .snowGrains, .snowShowers: return .cyan
        case .thunderstorm, .thunderstormHail: return .purple
        }
    }
}
