import SwiftUI
import WeatherCore

/// Asked once, the first time the app opens: which units to show. The phone's region picks the
/// suggested set (or the units already in Settings, for someone updating). Every unit can still be
/// changed on its own in Settings.
struct UnitsWelcomeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var choice: UnitPreset

    init() {
        let start = UnitSettings.hasSaved() ? UnitSettings.current.preset : nil
        _choice = State(initialValue: start ?? UnitPreset.deviceDefault)
    }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(systemName: "ruler")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Which units do you use?")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text("Temperatures, wind, rain and snow, distances and pressure all follow your choice, on every screen, widget and notification.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.top, 28)

            VStack(spacing: 10) {
                ForEach(UnitPreset.allCases, id: \.self) { preset in
                    Button { choice = preset } label: { row(preset) }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(choice == preset ? .isSelected : [])
                }
            }

            Text("You can change any single unit later in Settings.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.75))

            Spacer(minLength: 0)

            Button {
                choice.settings.save()
                UserDefaults.standard.set(true, forKey: UnitSettings.chosenKey)
                dismiss()
            } label: {
                Text("Continue").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.blue)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SkyBackground().ignoresSafeArea())
        .interactiveDismissDisabled()
    }

    private func row(_ preset: UnitPreset) -> some View {
        let s = preset.settings
        let sample = [WeatherFormat.temperature(21, unit: s.temperature),
                      WeatherFormat.wind(20, unit: s.wind),
                      WeatherFormat.precipitationTotals(rainMm: 25, snowCm: nil, unit: s.precipitation) ?? "",
                      WeatherFormat.distance(3, unit: s.distance) ?? ""].joined(separator: " · ")
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(preset.label).font(.headline)
                Text(preset.detail).font(.subheadline).foregroundStyle(.white.opacity(0.85))
                Text("e.g. \(sample)").font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Image(systemName: choice == preset ? "checkmark.circle.fill" : "circle")
                .font(.title2)
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(.white.opacity(choice == preset ? 0.25 : 0.1), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(choice == preset ? 0.8 : 0.2), lineWidth: 1.5))
        .contentShape(Rectangle())
    }
}
