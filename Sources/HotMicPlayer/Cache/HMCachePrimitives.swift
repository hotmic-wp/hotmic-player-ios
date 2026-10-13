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

/// HLS reading for prefetch. URIs resolve exactly as `HMPlaylist.rewrite` resolves
/// them for AVPlayer, so prefetched playlists are found under the URLs AVPlayer asks for.
enum HMHLS {
    struct Variant: Equatable { let bandwidth: Double; let audioGroup: String?; let url: URL }
    /// Playlist text without a byte-order mark, or nil when it is not a playlist.
    static func text(_ data: Data) -> String? {
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text.hasPrefix("#EXTM3U") ? text : nil
    }
    /// Lines split on LF, CR or CRLF (RFC 8216 allows both terminators), trimmed, blank lines dropped.
    static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    /// The attribute list after a tag's colon; quoted values are unquoted.
    static func attributes(_ line: String) -> [String: String] {
        guard let colon = line.firstIndex(of: ":") else { return [:] }
        var result: [String: String] = [:]
        var name = "", value = "", inName = true, quoted = false
        for ch in line[line.index(after: colon)...] {
            if inName {
                if ch == "=" { inName = false } else { name.append(ch) }
            } else if ch == "\"" { quoted.toggle() }
            else if ch == ",", !quoted {
                result[name.trimmingCharacters(in: .whitespaces)] = value; name = ""; value = ""; inName = true
            } else { value.append(ch) }
        }
        if !inName { result[name.trimmingCharacters(in: .whitespaces)] = value }
        return result
    }
    static func isMultivariant(_ text: String) -> Bool { lines(text).contains { $0.hasPrefix("#EXT-X-STREAM-INF") } }
    /// Multivariant playlists are not reloaded by clients and VOD media playlists cannot
    /// change, so neither needs a freshness TTL. Live and EVENT media playlists do.
    static func isImmutable(_ text: String) -> Bool {
        lines(text).contains { $0.hasPrefix("#EXT-X-STREAM-INF") || $0 == "#EXT-X-ENDLIST" || $0 == "#EXT-X-PLAYLIST-TYPE:VOD" }
    }
    /// Variants in listed order. The URI is the next non-tag line after each `#EXT-X-STREAM-INF`.
    static func variants(_ text: String, base: URL) -> [Variant] {
        var result: [Variant] = []
        var pending: [String: String]?
        for line in lines(text) {
            if line.hasPrefix("#EXT-X-STREAM-INF:") { pending = attributes(line); continue }
            guard !line.hasPrefix("#"), let tag = pending else { continue }
            pending = nil
            guard let url = URL(string: line, relativeTo: base)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            result.append(Variant(bandwidth: tag["BANDWIDTH"].flatMap { Double($0) } ?? 0, audioGroup: tag["AUDIO"], url: url))
        }
        return result
    }
    /// Prefetch heuristic: highest BANDWIDTH at or under the cap, else lowest.
    /// AVPlayer independently selects a rendition using throughput, audio and device
    /// conditions; preferredPeakBitRate is a preference, not an exact rendition lock.
    /// Uncapped prefetch selects the highest. Ties keep the first-listed variant.
    static func startVariant(_ variants: [Variant], cap: Double) -> Variant? {
        let eligible = cap > 0 ? variants.filter { $0.bandwidth <= cap } : variants
        // min/max(by:) keep the first of equal elements.
        guard !eligible.isEmpty else { return variants.min { $0.bandwidth < $1.bandwidth } }
        return eligible.max { $0.bandwidth < $1.bandwidth }
    }
    /// The demuxed audio rendition a variant's `AUDIO` group starts with: `DEFAULT=YES`,
    /// else `AUTOSELECT=YES`, else the first listed. Nil when the variant's audio is muxed.
    static func audioRendition(_ text: String, group: String?, base: URL) -> URL? {
        guard let group else { return nil }
        let renditions = lines(text).filter { $0.hasPrefix("#EXT-X-MEDIA:") }.map(attributes)
            .filter { $0["TYPE"] == "AUDIO" && $0["GROUP-ID"] == group && $0["URI"] != nil }
        guard let chosen = renditions.first(where: { $0["DEFAULT"] == "YES" }) ?? renditions.first(where: { $0["AUTOSELECT"] == "YES" }) ?? renditions.first,
              let url = URL(string: chosen["URI"]!, relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
}

/// In-memory playlists, kept while any owning window item remains. Immutable playlists
/// (`HMHLS.isImmutable`) never expire; the others expire after the TTL. A TTL of zero
/// disables playlist memory entirely, as before.
struct HMPlaylistMemory<Value> {
    private struct Entry { let value: Value; var owners: Set<String>; let storedAt: TimeInterval; let immutable: Bool }
    private var entries: [String: Entry] = [:]
    var count: Int { entries.count }
    func value(for url: String, now: TimeInterval, ttl: TimeInterval) -> Value? {
        guard ttl > 0, let entry = entries[url], entry.immutable || now - entry.storedAt < ttl else { return nil }
        return entry.value
    }
    func contains(owner: String) -> Bool { entries.values.contains { $0.owners.contains(owner) } }
    mutating func store(_ value: Value, for url: String, owner: String, immutable: Bool, now: TimeInterval) {
        let owners = (entries[url]?.owners ?? []).union([owner])
        entries[url] = Entry(value: value, owners: owners, storedAt: now, immutable: immutable)
    }
    mutating func associate(_ key: String, owner: String) {
        guard var entry = entries[key] else { return }; entry.owners.insert(owner); entries[key] = entry
    }
    /// Drops expired entries and entries whose owners all left the window.
    mutating func retain(owners: Set<String>, now: TimeInterval, ttl: TimeInterval) {
        entries = entries.compactMapValues { (stored: Entry) -> Entry? in
            var entry = stored
            entry.owners.formIntersection(owners)
            guard ttl > 0, !entry.owners.isEmpty, entry.immutable || now - entry.storedAt < ttl else { return nil }
            return entry
        }
    }
}

/// Selects complete audio/video/init resources under one per-entry payload budget.
/// HEAD metadata (count == 0) determines whether a whole resource fits before a
/// body is requested. A failed or unattainable target never counts partial media.
struct HMHLSPrefetcher: Sendable {
    struct Response: Sendable { let data: Data; let total: Int; let base: URL }
    struct Outcome: Sendable { let seconds: Double; let targetMet: Bool; let reason: String; let bytes: Int }
    struct Resource: Hashable { let url: URL; let start: Int; let count: Int? }
    struct Step { let resources: [Resource]; let duration: Double }
    typealias Load = @Sendable (_ url: URL, _ start: Int, _ count: Int) async throws -> Response
    static let playlistRead = 64 * 1024
    static let chunk = 512 * 1024
    let budget: Int
    let seconds: Double?
    let cap: Double

    func run(_ root: URL, load: Load) async throws -> Outcome {
        var remaining = max(0, budget)
        func outcome(_ elapsed: [Double], _ reason: String) -> Outcome {
            let reached = elapsed.min() ?? 0
            return Outcome(seconds: reached, targetMet: seconds.map { reached >= $0 } ?? (reason == "complete"),
                reason: reason, bytes: budget - remaining)
        }
        func playlist(_ url: URL) async throws -> (base: URL, text: String)? {
            let head = try await load(url, 0, 0)
            guard head.total > 0, head.total <= min(remaining, Self.playlistRead) else { return nil }
            let response = try await load(url, 0, head.total)
            remaining -= response.data.count
            guard response.data.count == response.total, let text = HMHLS.text(response.data) else { return nil }
            return (response.base, text)
        }
        guard let top = try await playlist(root) else { return outcome([], "playlist-unavailable-or-over-budget") }
        var media: [(base: URL, text: String)] = []
        if HMHLS.isMultivariant(top.text) {
            let variants = HMHLS.variants(top.text, base: top.base)
            guard let selected = HMHLS.startVariant(variants, cap: cap), let video = try await playlist(selected.url),
                  !HMHLS.isMultivariant(video.text) else { return outcome([], "video-playlist-unavailable") }
            if let audioURL = HMHLS.audioRendition(top.text, group: selected.audioGroup, base: top.base) {
                guard let audio = try await playlist(audioURL), !HMHLS.isMultivariant(audio.text) else { return outcome([], "audio-playlist-unavailable") }
                media.append(audio)
            }
            media.append(video)
            // AVPlayer may inspect the first listed variant before applying its cap.
            if let first = variants.first, first.url != selected.url {
                do { _ = try await playlist(first.url) } catch { try Task.checkCancellation() }
            }
        } else { media = [top] }
        guard !media.contains(where: { $0.text.contains("#EXT-X-DEFINE:") }) else { return outcome([], "variable-playlist-unsupported") }
        let plans = media.map { Self.steps($0.text, base: $0.base) }
        guard plans.allSatisfy({ !$0.isEmpty }) else { return outcome([], "no-complete-media-segments") }
        var next = plans.map { _ in 0 }, elapsed = plans.map { _ in 0.0 }
        var fetched: Set<Resource> = []
        while true {
            let tracks = plans.indices.filter { next[$0] < plans[$0].count && (seconds == nil || elapsed[$0] < seconds!) }
            guard !tracks.isEmpty else { return outcome(elapsed, seconds.map { (elapsed.min() ?? 0) >= $0 } == false ? "media-ended-before-target" : "complete") }
            var resources: [(Resource, Int)] = [], seen = fetched
            var requiredBytes = 0
            // Admit the entire audio/video round before downloading any of it.
            // This avoids spending the budget on video that has no playable audio.
            for track in tracks {
                for resource in plans[track][next[track]].resources where seen.insert(resource).inserted {
                    let head = try await load(resource.url, resource.start, 0)
                    let count = resource.count ?? max(0, head.total - resource.start)
                    guard count > 0, resource.start >= 0, resource.start <= head.total - count else { return outcome(elapsed, "invalid-resource-range") }
                    guard count <= remaining - requiredBytes else { return outcome(elapsed, "byte-cap-before-target") }
                    requiredBytes += count
                    resources.append((resource, count))
                }
            }
            for (resource, count) in resources {
                var offset = 0
                while offset < count {
                    try Task.checkCancellation()
                    let response = try await load(resource.url, resource.start + offset, min(Self.chunk, count - offset))
                    guard !response.data.isEmpty, response.data.count <= count - offset else { throw URLError(.badServerResponse) }
                    offset += response.data.count; remaining -= response.data.count
                }
                fetched.insert(resource)
            }
            for track in tracks { elapsed[track] += plans[track][next[track]].duration; next[track] += 1 }
        }
    }
    /// Groups init/key dependencies with the following complete segment, including
    /// EXT-X-BYTERANGE and MAP BYTERANGE offsets for fMP4 byte-range playlists.
    static func steps(_ text: String, base: URL) -> [Step] {
        var result: [Step] = [], dependencies: [Resource] = []
        var duration = 0.0, byteRange: String?
        var offsets: [URL: Int] = [:]
        func resource(_ url: URL, range: String?) -> Resource? {
            guard let range else { return Resource(url: url, start: 0, count: nil) }
            let pair = range.split(separator: "@", omittingEmptySubsequences: false)
            guard let count = Int(pair[0]), count > 0 else { return nil }
            let start = pair.count == 2 ? Int(pair[1]) : offsets[url]
            guard let start, start >= 0, start <= Int.max - count else { return nil }
            offsets[url] = start + count
            return Resource(url: url, start: start, count: count)
        }
        for line in HMHLS.lines(text) {
            if line.hasPrefix("#EXTINF:") { duration = Double(line.dropFirst(8).split(separator: ",").first ?? "0") ?? 0 }
            if line.hasPrefix("#EXT-X-BYTERANGE:") { byteRange = String(line.dropFirst(17)); continue }
            let references = HMPlaylist.references(line, base: base)
            if line.hasPrefix("#") {
                let range = line.hasPrefix("#EXT-X-MAP:") ? HMHLS.attributes(line)["BYTERANGE"] : nil
                for url in references { guard let entry = resource(url, range: range) else { return [] }; dependencies.append(entry) }
            } else if let url = references.first {
                guard duration.isFinite, duration > 0, let segment = resource(url, range: byteRange) else { return [] }
                result.append(Step(resources: dependencies + [segment], duration: duration))
                dependencies.removeAll(); byteRange = nil; duration = 0
            }
        }
        return result
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
    /// A stall is buffering after this activation reached `playing`. Before that, a wait
    /// after the first frame is AVPlayer's startup keep-up check on a progressive download;
    /// it counts only while less than a second is buffered.
    static func isStalling(buffering: Bool, hasPlayed: Bool, bufferedAhead: Double) -> Bool {
        buffering && (hasPlayed || !(bufferedAhead >= 1))
    }
    /// At binge pace a viewer leaves before a cold start finishes, so holding the next item
    /// back for the current item's start keeps both cold. At a measured dwell at or under
    /// `bingeDwell`, the next item's prefix may load through the current item's start, its
    /// wait before it first plays (however little is buffered) and buffer-safety pauses.
    /// A rebuffer after this activation played still holds it. A warm start's imminent frame holds
    /// a new one, but a prefix already `inFlight` keeps loading: cancelling it drops bytes a swipe needs.
    static func admitsNextHead(displayed: Bool, warmStart: Bool, rebuffering: Bool, dwell: Double?, bingeDwell: Double,
                               inFlight: Bool = false) -> Bool {
        guard !rebuffering, displayed || !warmStart || inFlight, let dwell, dwell.isFinite, dwell > 0 else { return false }
        return dwell <= max(0, bingeDwell)
    }
    /// An admitted next item that nothing has fetched gets its head before its pool player. After a
    /// warm start the plan resumes at once, and a native preroll beside the current item's stream
    /// lands after the swipe. A head already issued that cached nothing falls back to the preroll.
    static func headDue(admitted: Bool, issued: Bool, cachedBytes: Int) -> Bool {
        admitted && !issued && cachedBytes <= 0
    }
    /// The next item's pool player waits for its head. At the fast tier it may join a head the
    /// transport is downloading; an issued or queued head has nothing to join yet, and the player's
    /// first probe would reach the origin beside it.
    static func nextPlayerMayStart(headDue: Bool, headLoading: Bool, headRunning: Bool, fastTier: Bool) -> Bool {
        !headDue && (!headLoading || (fastTier && headRunning))
    }
}

/// AVPlayer starts on the highest rung at or under `preferredPeakBitRate` only while its own
/// throughput estimate clears the cap; on a slower link it starts lower, and a prefix of the
/// capped rung goes unused. Below the fast tier the start cap drops to the slow start rate,
/// which guides AVPlayer and the prefetch heuristic. Lowering needs `minimumSamples`
/// throughput samples and follows the speed tiers' hysteresis.
enum HMStartCap {
    static let minimumSamples = 3
    static func isLowered(throughput: Double?, samples: Int, wasLowered: Bool, thresholds t: HMAdaptivePrefetchThresholds) -> Bool {
        guard let throughput, throughput.isFinite, samples >= minimumSamples else { return false }
        let fast = nonnegative(t.fastBytesPerSecond), band = min(1, nonnegative(t.speedHysteresisFraction))
        return throughput < fast * (wasLowered ? 1 + band : 1 - band)
    }
    /// Zero (unrestricted) stays unrestricted: AVPlayer then makes its own pick.
    static func bitRate(_ cap: Double, lowered: Bool, thresholds t: HMAdaptivePrefetchThresholds) -> Double {
        let slow = nonnegative(t.slowBitRate)
        guard lowered, cap > 0, slow > 0 else { return cap }
        return min(cap, slow)
    }
}

enum HMNextWarmSafety {
    static func isSafe(ahead: Double, remaining: Double?, stalling: Bool, slow: Bool, wasWarm: Bool) -> Bool {
        guard ahead.isFinite, !stalling, !slow else { return false }
        return ahead >= min(wasWarm ? 0.25 : 1, remaining ?? 1)
    }
}
