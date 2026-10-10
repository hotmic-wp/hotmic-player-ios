import Foundation

struct HMCaptionCue: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// Plain text WebVTT cues. Cue positioning is intentionally replaced by the host's safe caption region.
enum HMWebVTT {
    static func parse(_ source: String) -> [HMCaptionCue] {
        let normalized = source.replacingOccurrences(of: "\u{feff}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard normalized.hasPrefix("WEBVTT") else { return [] }
        return normalized.components(separatedBy: "\n").split(whereSeparator: { $0.trimmingCharacters(in: .whitespaces).isEmpty }).compactMap { block in
            let lines = Array(block)
            let first = lines[0]
            guard !(first == "NOTE" || first.hasPrefix("NOTE ") || first.hasPrefix("NOTE\t") || first == "STYLE" || first == "REGION"),
                  let timing = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let times = lines[timing].components(separatedBy: "-->")
            guard times.count == 2, let start = timestamp(times[0]), let end = timestamp(times[1]), end > start else { return nil }
            let text = decode(lines.dropFirst(timing + 1).joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            )
            return text.isEmpty ? nil : HMCaptionCue(start: start, end: end, text: text)
        }.sorted { $0.start < $1.start }
    }
    private static func decode(_ source: String) -> String {
        var text = source
        let pattern = try! NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);")
        for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard let tokenRange = Range(match.range(at: 1), in: source), let range = Range(match.range, in: text) else { continue }
            let token = String(source[tokenRange])
            let number = token.hasPrefix("x") ? UInt32(token.dropFirst(), radix: 16) : UInt32(token)
            guard let number, number != 0, let scalar = UnicodeScalar(number) else { continue }
            text.replaceSubrange(range, with: String(scalar))
        }
        for (entity, value) in [("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&lrm;", "\u{200e}"), ("&rlm;", "\u{200f}"), ("&quot;", "\""), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text
    }
    private static func timestamp(_ value: String) -> TimeInterval? {
        guard let token = value.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        let parts = token.split(separator: ":")
        guard (2...3).contains(parts.count), let seconds = Double(parts.last!), seconds >= 0, seconds < 60,
              let minutes = Double(parts[parts.count - 2]), minutes >= 0, minutes < 60 else { return nil }
        let hours = parts.count == 3 ? Double(parts[0]) : 0
        guard let hours, hours >= 0 else { return nil }
        let result = hours * 3600 + minutes * 60 + seconds
        return result.isFinite ? result : nil
    }
}

/// Shared seek policy for SDK surfaces and partner-built controls.
public enum HMAccessibility {
    /// VoiceOver increment/decrement seeks ten seconds, clamped to the seekable range.
    public static let seekStep: TimeInterval = 10
    /// Returns a finite target inside the currently seekable interval.
    public static func seekTarget(position: TimeInterval, start: TimeInterval, duration: TimeInterval, increment: Bool) -> TimeInterval {
        guard position.isFinite, start.isFinite, duration.isFinite, duration > 0 else { return max(0, start.isFinite ? start : 0) }
        return min(start + duration, max(start, position + (increment ? seekStep : -seekStep)))
    }
}
