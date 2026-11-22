import Foundation

/// Makes official alert text short enough to read on a phone: drops the stock lines every alert
/// repeats ("Please continue to monitor alerts...", the report-by-email line, hashtags, "advisories
/// are issued when...") and joins hard-wrapped lines back into paragraphs.
public enum AlertText {
    /// Sentences containing any of these (lowercased) are boilerplate.
    static let boilerplate = [
        "continue to monitor",
        "report severe weather",
        "@ec.gc.ca",
        "are issued when",
        "is issued when",
        "for more information",
        "weather.gc.ca",
        "canada.ca",
        "getprepared",
        "visit www.",
        "please refer to",
    ]

    /// The useful paragraphs, in order. Falls back to the raw text if everything looked like boilerplate.
    public static func paragraphs(_ raw: String, units: UnitSettings = .current) -> [String] {
        plainParagraphs(raw).map { withUnits($0, units: units) }
    }

    static func plainParagraphs(_ raw: String) -> [String] {
        let paras = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map(normalise)
            .filter { !$0.isEmpty }
        let kept = paras.compactMap { para -> String? in
            let sentences = splitSentences(para).filter { !isBoilerplate($0) }
            let joined = sentences.joined(separator: " ")
            return joined.isEmpty ? nil : joined
        }
        return kept.isEmpty ? paras : kept
    }

    /// All useful text as one flowing block, for a collapsed preview or a notification.
    public static func summary(_ raw: String, units: UnitSettings = .current) -> String {
        paragraphs(raw, units: units).joined(separator: " ")
    }

    // MARK: Units in the official text

    /// Official alerts give amounts in their own country's units ("50 to 75 mm", "gusts of 90
    /// km/h", "6 inches", "60 mph"). When those aren't the person's units, add theirs after the
    /// original, which stays word for word: "50 to 75 mm (2 to 3 in)".
    public static func withUnits(_ text: String, units: UnitSettings) -> String {
        let number = #"([-−]?\d+(?:\.\d+)?)"#
        let pattern = number + #"(?:\s*(?:to|-|–|and)\s*"# + number + #")?\s*(mm|cm|km/h|kph|km|inches|inch|in\.|mph|miles|mile|°C|°F)(?![\w/])(?!\s*\()"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            func value(_ i: Int) -> Double? {
                m.range(at: i).location == NSNotFound ? nil
                    : Double(ns.substring(with: m.range(at: i)).replacingOccurrences(of: "−", with: "-"))
            }
            let a = value(1)
            let b = value(2)
            let unit = ns.substring(with: m.range(at: 3)).lowercased()
            out += ns.substring(with: NSRange(location: last, length: m.range.upperBound - last))
            last = m.range.upperBound
            if let a, let extra = converted(a, b, unit: unit, units: units) { out += " (\(extra))" }
        }
        out += ns.substring(from: last)
        return out
    }

    /// "2 to 3 in" for (50, 75, "mm") in US units; nil when the text already uses the person's units.
    static func converted(_ a: Double, _ b: Double?, unit: String, units: UnitSettings) -> String? {
        func one(_ x: Double, decimals: Bool) -> String {
            if decimals && x < 1 { return String(format: "%.1f", max(0.1, (x * 10).rounded() / 10)) }
            return "\(Int(x.rounded()))"
        }
        func show(_ f: (Double) -> Double, _ label: String, decimals: Bool) -> String {
            let first = one(f(a), decimals: decimals)
            let text = b.map { "\(first) to \(one(f($0), decimals: decimals))" } ?? first
            return text + (label.hasPrefix("°") ? "" : " ") + label
        }
        let inches = units.precipitation == .inches
        let miles = units.distance == .mi
        let f = units.temperature == .fahrenheit
        switch unit {
        case "mm": return inches ? show({ $0 / 25.4 }, "in", decimals: true) : nil
        case "cm": return inches ? show({ $0 / 2.54 }, "in", decimals: true) : nil
        case "inches", "inch", "in.": return inches ? nil : show({ $0 * 25.4 }, "mm", decimals: false)
        case "km/h", "kph": return units.wind == .kmh ? nil : show({ units.wind.convert($0) }, units.wind.label, decimals: false)
        case "mph": return units.wind == .mph ? nil : show({ units.wind.convert($0 * 1.609344) }, units.wind.label, decimals: false)
        case "km": return miles ? show({ $0 / 1.609344 }, "miles", decimals: true) : nil
        case "miles", "mile": return miles ? nil : show({ $0 * 1.609344 }, "km", decimals: true)
        case "°c": return f ? show({ $0 * 9 / 5 + 32 }, "°F", decimals: false) : nil
        case "°f": return f ? nil : show({ ($0 - 32) * 5 / 9 }, "°C", decimals: false)
        default: return nil
        }
    }

    static func normalise(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func splitSentences(_ para: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(para)
        for (i, c) in chars.enumerated() {
            current.append(c)
            // A sentence ends at . ! ? followed by a space (so "ec.gc.ca" and "10.5" stay whole).
            if ".!?".contains(c), i + 1 < chars.count, chars[i + 1] == " " {
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    static func isBoilerplate(_ sentence: String) -> Bool {
        let s = sentence.lowercased()
        if s == "###" || s.allSatisfy({ $0 == "#" || $0 == " " }) { return true }
        if boilerplate.contains(where: s.contains) { return true }
        // Hashtag-only lines like "#ONStorm" or "#BCStorm".
        if s.hasPrefix("#") && !s.contains(" ") { return true }
        return false
    }
}

extension WeatherAlert {
    /// The alert text without the stock lines, as paragraphs.
    public var readableParagraphs: [String] { AlertText.paragraphs(text) }  // in the person's units

    /// The alert text without the stock lines, as one block.
    public var summary: String { AlertText.summary(text) }

    /// Notification text: the useful lines only, cut at a word near 240 characters.
    public var notificationBody: String {
        let s = summary
        guard s.count > 240 else { return s }
        let cut = s.prefix(240)
        let end = cut.lastIndex(of: " ") ?? cut.endIndex
        return String(cut[..<end]) + "…"
    }

    /// Environment Canada's colour-coded name, e.g. "Yellow advisory - fog" for a yellow fog
    /// advisory. Falls back to the plain title when there's no colour or the name doesn't fit.
    public var headline: String {
        guard risk != .unknown else { return title }
        let kindWord: String
        switch kind {
        case .warning: kindWord = "warning"
        case .watch: kindWord = "watch"
        case .advisory: kindWord = "advisory"
        case .statement, .other: return title
        }
        let lower = title.lowercased()
        guard lower.hasSuffix(" " + kindWord) else { return title }
        let hazard = lower.dropLast(kindWord.count + 1).trimmingCharacters(in: .whitespaces)
        guard !hazard.isEmpty else { return title }
        return "\(risk.rawValue.capitalized) \(kindWord) - \(hazard)"
    }
}
