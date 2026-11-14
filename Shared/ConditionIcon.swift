import SwiftUI
import WeatherCore

/// Full-colour weather symbol: yellow sun, white clouds, blue rain, yellow lightning.
/// On dark backgrounds (the sky screens and widgets) it uses SF Symbols' own multicolour art.
/// Multicolour clouds are white, which vanishes on light backgrounds, so light screens get
/// grey clouds with a coloured accent instead.
struct ConditionIcon: View {
    let condition: WeatherCondition
    var isDay: Bool = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let image = Image(systemName: condition.symbolName(isDay: isDay))
        if colorScheme == .dark {
            image
                .symbolRenderingMode(.multicolor)
                .foregroundStyle(.white)
        } else if condition == .clear {
            image.symbolRenderingMode(.multicolor).foregroundStyle(isDay ? Color.yellow : Color.indigo)
        } else {
            image.symbolRenderingMode(.palette).foregroundStyle(Color.gray, accent)
        }
    }

    /// Colour for the sun, moon, drops or flakes.
    private var accent: Color {
        switch condition {
        case .clear, .mainlyClear, .partlyCloudy: return isDay ? .orange : .indigo
        case .overcast, .fog, .unknown: return .gray
        case .drizzle, .rain, .rainShowers: return .blue
        case .freezingDrizzle, .freezingRain: return .teal
        case .snow, .snowGrains, .snowShowers: return .cyan
        case .thunderstorm, .thunderstormHail: return .yellow
        }
    }
}
