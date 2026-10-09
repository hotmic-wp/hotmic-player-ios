import Foundation
import CryptoKit

/// Closed HTTP byte range, including suffix and open-ended forms.
struct HMByteRange: Equatable {
    let start: Int
    let end: Int
    var count: Int { end - start + 1 }
    static func parse(_ header: String?, total: Int, limit: Int = 512 * 1024) -> Self? {
        guard total > 0 else { return nil }
        guard let header else { return Self(start: 0, end: min(total, limit) - 1) }
        guard header.hasPrefix("bytes="), !header.contains(",") else { return nil }
        let pair = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard pair.count == 2 else { return nil }
        if pair[0].isEmpty {
            guard let suffix = Int(pair[1]), suffix > 0 else { return nil }
            let start = max(0, total - suffix)
            return Self(start: start, end: min(total - 1, start + min(limit, total - start) - 1))
        }
        guard let start = Int(pair[0]), start >= 0, start < total else { return nil }
        let requestedEnd: Int
        if pair[1].isEmpty { requestedEnd = total - 1 }
        else { guard let e = Int(pair[1]), e >= start else { return nil }; requestedEnd = e }
        return Self(start: start, end: min(total - 1, requestedEnd, start + min(limit, total - start) - 1))
    }
}

enum HMCacheKey {
    /// Query values are media identity unless explicitly declared volatile.
    static func canonical(_ url: URL, ignoring parameters: [String] = []) -> String {
        guard !parameters.isEmpty, var c = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url.absoluteString }
        let ignored = Set(parameters)
        c.queryItems = c.queryItems?.filter { !ignored.contains($0.name) }
        if c.queryItems?.isEmpty == true { c.query = nil }
        return c.string ?? url.absoluteString
    }
    static func mime(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "ts": return "video/mp2t"
        case "m4s", "mp4": return "video/mp4"
        case "aac": return "audio/aac"
        case "vtt": return "text/vtt"
        default: return "application/octet-stream"
        }
    }
    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Rewrites both URI lines and quoted URI attributes (MAP, KEY, MEDIA, etc.).
/// Relative references resolve against the final response URL after redirects.
enum HMPlaylist {
    static func rewrite(_ text: String, base: URL, proxy: (URL) -> URL) -> String {
        let regex = try! NSRegularExpression(pattern: "URI=\"([^\"]+)\"")
        return text.components(separatedBy: "\n").map { line in
            if !line.isEmpty, !line.hasPrefix("#") {
                guard let u = URL(string: line.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: base)?.absoluteURL else { return line }
                guard ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { return line }
                return proxy(u).absoluteString
            }
            var result = line
            let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
            for match in matches.reversed() {
                guard let range = Range(match.range(at: 1), in: result),
                      let u = URL(string: String(result[range]), relativeTo: base)?.absoluteURL else { continue }
                guard ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { continue }
                result.replaceSubrange(range, with: proxy(u).absoluteString)
            }
            return result
        }.joined(separator: "\n")
    }
    static func references(_ text: String, base: URL) -> [URL] {
        var urls: [URL] = []
        _ = rewrite(text, base: base) { u in urls.append(u); return u }
        return urls
    }
}

/// Union/intersection avoids counting repeated AVFoundation probes as newly
/// consumed prefetch. Units are payload bytes, excluding protocol overhead.
enum HMRangeCoverage {
    static func union(_ ranges: [HMByteRange]) -> [HMByteRange] {
        var result: [HMByteRange] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) {
            if let previous = result.last, range.start <= previous.end + 1 {
                result[result.count - 1] = HMByteRange(start: previous.start, end: max(previous.end, range.end))
            } else { result.append(range) }
        }
        return result
    }
    static func overlap(_ a: [HMByteRange], _ b: [HMByteRange]) -> Int {
        let left = union(a), right = union(b)
        return left.reduce(0) { sum, l in
            sum + right.reduce(0) { $0 + max(0, min(l.end, $1.end) - max(l.start, $1.start) + 1) }
        }
    }
}

/// Completed and failed windows remain remembered until explicit cancellation.
/// An unchanged buffer tick cannot create a new run or retry an exhausted item.
struct HMPrefetchEpoch {
    private(set) var generation = 0
    private var window: String?
    func matches(_ identity: String) -> Bool { window == identity }
    mutating func begin(_ identity: String) -> Int? {
        guard !matches(identity) else { return nil }
        generation += 1; window = identity; return generation
    }
    mutating func cancel() { generation += 1; window = nil }
}

enum HMBufferSafety {
    static func isSafe(ahead: Double, remaining: Double, hasDuration: Bool, threshold: Double, wasSafe: Bool) -> Bool {
        (hasDuration && ahead >= remaining - 0.1) || ahead >= max(0, threshold) * (wasSafe ? 0.5 : 1)
    }
}

enum HMPlaybackPriority {
    static func isUrgent(displayed: Bool, stalling: Bool) -> Bool { !displayed || stalling }
}
