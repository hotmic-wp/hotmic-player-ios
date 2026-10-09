import Foundation
@_spi(Benchmark) import HotMicPlayer

/// --hm-name value overrides HM_NAME; strategy is only a preset, then all
/// supplied knobs apply independently. Invalid values stop the run visibly.
struct BenchmarkOptions {
    let values: [String: String]
    init(values: [String: String]) { self.values = values }
    init(environment: [String: String] = ProcessInfo.processInfo.environment, arguments: [String] = ProcessInfo.processInfo.arguments) {
        var result: [String: String] = [:]
        for (key, value) in environment where key.hasPrefix("HM_") { result[String(key.dropFirst(3)).lowercased().replacingOccurrences(of: "_", with: "-")] = value }
        var i = 1
        while i < arguments.count {
            if arguments[i].hasPrefix("--hm-"), i + 1 < arguments.count {
                result[String(arguments[i].dropFirst(5))] = arguments[i + 1]; i += 2
            } else { i += 1 }
        }
        values = result
    }
    var enabled: Bool { values["run-id"] != nil || values["auto-start"] == "1" }
    var runID: String { values["run-id"] ?? UUID().uuidString }
    var script: String { values["script"] ?? "manual" }
    var autoStart: Bool { values["auto-start"] == "1" }
    var startIndex: Int { Int(values["start-index"] ?? "0") ?? 0 }
    func configuration() throws -> HMPlayerConfiguration {
        guard let strategy = HMPlaybackStrategy(rawValue: values["strategy"] ?? "S3") else { throw Invalid("strategy") }
        var c = HMPlayerConfiguration.preset(strategy)
        func number(_ key: String, _ range: ClosedRange<Double>) throws -> Double? {
            guard let raw = values[key] else { return nil }
            guard let value = Double(raw), value.isFinite, range.contains(value) else { throw Invalid(key) }
            return value
        }
        if let n = try number("players", 1...4) { guard n.rounded() == n else { throw Invalid("players") }; c.poolSize = Int(n) }
        if let n = try number("ahead", 0...8) { guard n.rounded() == n else { throw Invalid("ahead") }; c.prefetch.ahead = Int(n) }
        if let n = try number("behind", 0...8) { guard n.rounded() == n else { throw Invalid("behind") }; c.prefetch.behind = Int(n) }
        if let n = try number("prefetch-bytes", 0...Double(HMPrefetchPolicy.maximumBytesPerItem)) { c.prefetch.bytesPerItem = Int(n) }
        if let n = try number("prefetch-seconds", 0...600) { c.prefetch.secondsPerItem = n }
        if let n = try number("threshold", 0...600) { c.prefetch.startThreshold = n }
        if let n = try number("cache-cap", 0...10_000_000_000) { c.cacheCapacityBytes = Int(n) }
        if let n = try number("startup-bitrate", 0...100_000_000) { c.startupPeakBitRate = n }
        if let n = try number("startup-window", 0...600) { c.startupBitRateWindow = n }
        if let n = try number("steady-bitrate", 0...100_000_000) { c.steadyPeakBitRate = n }
        if let n = try number("steady-buffer", 0...600) { c.steadyBufferDuration = n }
        if let n = try number("warm-buffer", 0...600) { c.prefetch.warmBufferDuration = n }
        if enabled { c.startsMuted = true; c.restoresPlaybackPosition = false }
        return c
    }
    func dataSource() async throws -> HMPlaylistSource {
        guard let raw = values["manifest-url"] else { return DemoContent.dataSource }
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme) else { throw Invalid("manifest-url") }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Invalid("manifest HTTP status") }
        struct Entry: Decodable { let id: String; let url: String; let poster: String?; let format: String; let duration: Double? }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        guard !entries.isEmpty, Set(entries.map(\.id)).count == entries.count else { throw Invalid("manifest empty or duplicate IDs") }
        let items = try entries.map { e -> HMMediaItem in
            guard let media = URL(string: e.url, relativeTo: url)?.absoluteURL, ["https", "http"].contains(media.scheme) else { throw Invalid("media URL") }
            return HMMediaItem(id: e.id, url: media, posterURL: e.poster.flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }, title: e.id, durationHint: e.duration, metadata: ["format": e.format])
        }
        return HMStaticPlaylistSource(items: items, pageSize: items.count, loopsForever: false, simulatedLatency: .zero)
    }
    struct Invalid: LocalizedError { let key: String; init(_ key: String) { self.key = key }; var errorDescription: String? { "Invalid benchmark option: \(key)" } }
}
