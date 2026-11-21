import SwiftUI
import WeatherCore

/// One alert as a card: colour-coded headline ("Yellow advisory - fog"), the area, a three-line
/// preview with the stock Environment Canada lines removed, and "1 hour ago · source". Tap to
/// read the rest. The card has its own dark surface so the text stays readable on any sky; the
/// risk colour is only an accent (edge stripe, icon and headline), never the background.
struct AlertBanner: View {
    let alert: WeatherAlert
    var timeZone: TimeZone = .current
    @State private var expanded: Bool

    init(alert: WeatherAlert, timeZone: TimeZone = .current, expanded: Bool = false) {
        self.alert = alert
        self.timeZone = timeZone
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
        } label: {
            card
        }
        .buttonStyle(.plain)
        .accessibilityHint(expanded ? "Shows less" : "Shows the full alert")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(alert.headline)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(accent)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: icon)
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.black.opacity(0.8), colour)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(alert.readableParagraphs.enumerated()), id: \.offset) { _, para in
                        Text(para)
                    }
                }
                .font(.callout)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(alert.summary)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .truncationMode(.tail)
            }

            HStack(spacing: 6) {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(expanded ? nil : 1)
                Spacer(minLength: 4)
                Image(systemName: expanded ? "chevron.up" : "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
            }

            if expanded, let issued = alert.issuedAt {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Issued \(issued.formatted(Self.style(timeZone)))")
                    if alert.source.contains("Canada") {
                        Link("Open on weather.gc.ca", destination: URL(string: "https://weather.gc.ca/warnings/index_e.html")!)
                            .foregroundStyle(accent)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding(16)
        .padding(.leading, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack(alignment: .leading) {
                Rectangle().fill(.ultraThinMaterial)
                // Dark enough for white text on the brightest sky (about 12:1 contrast).
                Rectangle().fill(Color(red: 0.07, green: 0.08, blue: 0.11).opacity(0.82))
                Rectangle().fill(colour.opacity(0.10))
                Rectangle().fill(colour).frame(width: 6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let area = alert.area { parts.append(area) }
        if let end = alert.eventEndsAt, end > Date() {
            parts.append("until \(end.formatted(Self.style(timeZone)))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "1 hour ago · Environment and Climate Change Canada".
    private var footer: String {
        guard let issued = alert.issuedAt else { return alert.source }
        let ago: String
        if Date().timeIntervalSince(issued) < 60 {
            ago = "Just now"
        } else {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .full
            ago = f.localizedString(for: issued, relativeTo: Date())
        }
        return "\(ago) · \(alert.source)"
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
        case .red: return Color(red: 0.92, green: 0.2, blue: 0.2)
        case .orange: return Color(red: 1.0, green: 0.55, blue: 0.1)
        case .yellow: return Color(red: 1.0, green: 0.82, blue: 0.1)
        case .unknown: return alert.kind == .warning ? Color(red: 1.0, green: 0.55, blue: 0.1) : .gray
        }
    }

    /// Headline colour: the risk colour, lightened where needed so it reads on the dark card.
    private var accent: Color {
        switch alert.risk {
        case .red: return Color(red: 1.0, green: 0.48, blue: 0.45)
        case .orange: return Color(red: 1.0, green: 0.66, blue: 0.3)
        case .yellow: return Color(red: 1.0, green: 0.85, blue: 0.3)
        case .unknown: return alert.kind == .warning ? Color(red: 1.0, green: 0.66, blue: 0.3) : .white
        }
    }

    static func style(_ tz: TimeZone) -> Date.FormatStyle {
        Date.FormatStyle(timeZone: tz).weekday(.abbreviated).hour().minute()
    }
}
