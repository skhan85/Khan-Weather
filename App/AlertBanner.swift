import SwiftUI
import WeatherCore

/// One alert, coloured by Environment Canada's risk colour. Tap to read the full text.
struct AlertBanner: View {
    let alert: WeatherAlert
    var timeZone: TimeZone = .current
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text(alert.text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let issued = alert.issuedAt {
                    Text("Issued \(issued.formatted(Self.style(timeZone)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Link("Source: \(alert.source)", destination: URL(string: "https://weather.gc.ca/warnings/index_e.html")!)
                    .font(.caption)
            }
            .padding(.top, 4)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(colour)
                VStack(alignment: .leading, spacing: 2) {
                    Text(alert.title)
                        .font(.headline)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listRowBackground(colour.opacity(0.18))
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let area = alert.area { parts.append(area) }
        if let end = alert.eventEndsAt, end > Date() {
            parts.append("until \(end.formatted(Self.style(timeZone)))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var icon: String {
        switch alert.kind {
        case .warning: return "exclamationmark.triangle.fill"
        case .watch: return "eye.fill"
        case .advisory: return "exclamationmark.circle.fill"
        case .statement, .other: return "info.circle.fill"
        }
    }

    private var colour: Color {
        switch alert.risk {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .unknown: return alert.kind == .warning ? .orange : .gray
        }
    }

    static func style(_ tz: TimeZone) -> Date.FormatStyle {
        Date.FormatStyle(timeZone: tz).weekday(.abbreviated).hour().minute()
    }
}
