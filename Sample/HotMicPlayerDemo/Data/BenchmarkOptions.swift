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
        if let n = try number("adaptive", 0...1) { guard n == 0 || n == 1 else { throw Invalid("adaptive") }; c.adaptive = n == 1 }
        if let n = try number("prefetch-concurrency", 0...4) { guard n.rounded() == n else { throw Invalid("prefetch-concurrency") }; c.maxPrefetchConcurrency = Int(n) }
        if let n = try number("cached-start-bytes", 0...Double(HMPrefetchPolicy.maximumBytesPerItem)) { c.minimumCachedStartBytes = Int(n) }
        if let n = try number("resolve-ahead", 0...32) { guard n.rounded() == n else { throw Invalid("resolve-ahead") }; c.resolveAhead = Int(n) }
        if let n = try number("adaptive-slow-bytes-per-second", 0...100_000_000) { c.adaptiveThresholds.slowBytesPerSecond = n }
        if let n = try number("adaptive-fast-bytes-per-second", 0...100_000_000) { c.adaptiveThresholds.fastBytesPerSecond = n }
        if let n = try number("adaptive-speed-hysteresis-fraction", 0...1) { c.adaptiveThresholds.speedHysteresisFraction = n }
        if let n = try number("adaptive-high-latency-seconds", 0...100_000_000) { c.adaptiveThresholds.highLatencySeconds = n }
        if let n = try number("adaptive-low-hit-rate", 0...1) { c.adaptiveThresholds.lowHitRate = n }
        if let n = try number("adaptive-binge-dwell-seconds", 0...100_000_000) { c.adaptiveThresholds.bingeDwellSeconds = n }
        if let n = try number("adaptive-long-dwell-seconds", 0...100_000_000) { c.adaptiveThresholds.longDwellSeconds = n }
        if let n = try number("adaptive-safety-buffer-seconds", 0...100_000_000) { c.adaptiveThresholds.safetyBufferSeconds = n }
        if let n = try number("adaptive-recovery-buffer-seconds", 0...100_000_000) { c.adaptiveThresholds.recoveryBufferSeconds = n }
        if let n = try number("adaptive-slow-budget-fraction", 0...1) { c.adaptiveThresholds.slowBudgetFraction = n }
        if let n = try number("adaptive-medium-budget-fraction", 0...1) { c.adaptiveThresholds.mediumBudgetFraction = n }
        if let n = try number("adaptive-binge-budget-multiplier", 0...100_000_000) { c.adaptiveThresholds.bingeBudgetMultiplier = n }
        if let n = try number("adaptive-long-dwell-budget-multiplier", 0...100_000_000) { c.adaptiveThresholds.longDwellBudgetMultiplier = n }
        if let n = try number("adaptive-long-dwell-delay-fraction", 0...1) { c.adaptiveThresholds.longDwellDelayFraction = n }
        if let n = try number("adaptive-maximum-delay-seconds", 0...100_000_000) { c.adaptiveThresholds.maximumDelaySeconds = n }
        if let n = try number("adaptive-slow-ahead", 0...32) { guard n.rounded() == n else { throw Invalid("adaptive-slow-ahead") }; c.adaptiveThresholds.slowAhead = Int(n) }
        if let n = try number("adaptive-medium-ahead", 0...32) { guard n.rounded() == n else { throw Invalid("adaptive-medium-ahead") }; c.adaptiveThresholds.mediumAhead = Int(n) }
        if let n = try number("adaptive-slow-bit-rate", 0...100_000_000) { c.adaptiveThresholds.slowBitRate = n }
        if let n = try number("adaptive-medium-bit-rate", 0...100_000_000) { c.adaptiveThresholds.mediumBitRate = n }
        if let n = try number("adaptive-fast-bit-rate", 0...100_000_000) { c.adaptiveThresholds.fastBitRate = n }
        if let n = try number("adaptive-ewma-alpha", 0...1) { c.adaptiveThresholds.ewmaAlpha = n }
        if enabled { c.startsMuted = true; c.restoresPlaybackPosition = false }
        return c
    }
    func dataSource() async throws -> HMPlaylistSource {
        guard let raw = values["manifest-url"] else { return try await DemoContent.dataSource() }
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme) else { throw Invalid("manifest-url") }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Invalid("manifest HTTP status") }
        struct Entry: Decodable { let id: String; let url: String; let poster: String?; let format: String; let duration: Double?; let aspectRatio: Double?; let captions: [String: String]? }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        guard !entries.isEmpty, Set(entries.map(\.id)).count == entries.count else { throw Invalid("manifest empty or duplicate IDs") }
        let items = try entries.map { e -> HMMediaItem in
            guard let media = URL(string: e.url, relativeTo: url)?.absoluteURL, ["https", "http"].contains(media.scheme) else { throw Invalid("media URL") }
            return HMMediaItem(id: e.id, url: media, posterURL: e.poster.flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }, title: e.id, durationHint: e.duration, metadata: ["format": e.format], aspectRatio: e.aspectRatio, captionSources: (e.captions ?? [:]).compactMapValues { URL(string: $0, relativeTo: url)?.absoluteURL })
        }
        return HMStaticPlaylistSource(items: items, pageSize: items.count, loopsForever: false, simulatedLatency: .zero)
    }
    struct Invalid: LocalizedError { let key: String; init(_ key: String) { self.key = key }; var errorDescription: String? { "Invalid benchmark option: \(key)" } }
}
