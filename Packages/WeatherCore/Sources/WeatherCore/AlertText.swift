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
    public static func paragraphs(_ raw: String) -> [String] {
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
    public static func summary(_ raw: String) -> String {
        paragraphs(raw).joined(separator: " ")
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
    public var readableParagraphs: [String] { AlertText.paragraphs(text) }

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
