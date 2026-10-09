import Foundation

/// Benchmark strategies: direct, data cache, warm pool and hybrid.
@_spi(Benchmark) public enum HMPlaybackStrategy: String, Sendable, Codable, CaseIterable {
    /// One direct player; no speculative media work.
    case S0
    /// One player plus bounded disk prefetch.
    case S1
    /// Prepared-player comparison strategy.
    case S2
    /// Two-player hybrid with bounded disk prefetch.
    case S3
    /// Whether the strategy uses bounded disk media caching.
    public var usesDataCache: Bool { self == .S1 || self == .S3 }
}

/// Nearest-first data window. S2 uses this same window for warm players.
public struct HMPrefetchPolicy: Sendable, Equatable {
    /// Number of following entries in the data window, bounded to 0...8.
    public var ahead: Int
    /// Number of preceding entries in the data window, bounded to 0...8.
    public var behind: Int
    /// Native player buffer target for prepared neighbours, in seconds.
    @_spi(Benchmark) public var warmBufferDuration: TimeInterval
    /// Maximum speculative bytes per entry, bounded by maximumBytesPerItem.
    public var bytesPerItem: Int
    /// Optional media-time budget; MP4 estimates bytes from duration/file size,
    /// HLS selects whole segments up to this duration, always bounded by bytes.
    public var secondsPerItem: TimeInterval?
    /// Current buffered seconds required before speculative media work starts.
    @_spi(Benchmark) public var startThreshold: TimeInterval

    /// Creates bounded playback and prefetch settings using the supplied tuning values.
    @_spi(Benchmark) public init(ahead: Int = 5, behind: Int = 1, warmBufferDuration: TimeInterval,
                bytesPerItem: Int = 800_000, secondsPerItem: TimeInterval? = nil,
                startThreshold: TimeInterval = 3) {
        self.ahead = max(0, min(8, ahead)); self.behind = max(0, min(8, behind))
        self.warmBufferDuration = warmBufferDuration
        self.bytesPerItem = max(0, min(Self.maximumBytesPerItem, bytesPerItem)); self.secondsPerItem = secondsPerItem
        self.startThreshold = startThreshold
    }
    /// Creates a fixed data window and bounded per-item media budgets.
    public init(ahead: Int = 5, behind: Int = 1, bytesPerItem: Int = 800_000, secondsPerItem: TimeInterval? = nil) {
        self.init(ahead: ahead, behind: behind, warmBufferDuration: 3, bytesPerItem: bytesPerItem, secondsPerItem: secondsPerItem)
    }
    /// Hard upper bound of 8 MiB for speculative bytes per entry.
    public static let maximumBytesPerItem = 8 * 1024 * 1024
    /// Disables speculative fetching.
    public static let off = HMPrefetchPolicy(ahead: 0, behind: 0, warmBufferDuration: 0)
    /// Prefetches only the next entry.
    public static let nextOnly = HMPrefetchPolicy(ahead: 1, behind: 0)
    /// Prefetches two ahead and one behind.
    public static let balanced = HMPrefetchPolicy(ahead: 2, behind: 1)
    /// Prefetches three ahead and two behind, with a five-second warm buffer.
    public static let aggressive = HMPrefetchPolicy(ahead: 3, behind: 2, warmBufferDuration: 5)
    var windowOffsets: [Int] {
        let a = max(0, min(8, ahead)), b = max(0, min(8, behind))
        guard max(a, b) > 0 else { return [] }
        return (1...max(a, b)).flatMap { d in
            (d <= a ? [d] : []) + (d <= b ? [-d] : [])
        }
    }
}

/// Playback, paging and cache settings for an HMPlayer.
public struct HMPlayerConfiguration: Sendable {
    /// Ask the playlist source for more when this many entries remain after current.
    @_spi(Benchmark) public var lowWaterMark: Int = 3
    /// Memory-only HLS playlist freshness, in seconds.
    public var playlistTTL: TimeInterval = 30
    /// Exact query parameter names to remove from cache identity. Empty is safe by default.
    @_spi(Benchmark) public var volatileSigningQueryParameters: [String] = []
    /// Benchmark playback strategy; S3 is the default hybrid.
    @_spi(Benchmark) public var strategy: HMPlaybackStrategy
    /// Native player count, bounded to 1...4 by the engine.
    public var poolSize: Int
    /// Fixed prefetch window and media budgets.
    public var prefetch: HMPrefetchPolicy
    /// Hard disk media cache cap, in bytes.
    public var cacheCapacityBytes: Int
    /// Current player forward-buffer target in seconds.
    @_spi(Benchmark) public var steadyBufferDuration: TimeInterval
    /// Initial bitrate ceiling in bits per second; zero leaves it unrestricted.
    public var startupPeakBitRate: Double
    /// Bitrate ceiling after startup in bits per second; zero leaves it unrestricted.
    @_spi(Benchmark) public var steadyPeakBitRate: Double
    /// Seconds after activation before lifting the startup ceiling.
    @_spi(Benchmark) public var startupBitRateWindow: TimeInterval
    /// Whether an item loops when it reaches its end.
    @_spi(Benchmark) public var loops: Bool
    /// Initial global mute state.
    @_spi(Benchmark) public var startsMuted: Bool
    /// Whether the SDK activates and deactivates the app audio session.
    @_spi(Benchmark) public var managesAudioSession: Bool
    /// Whether revisiting an entry restores its last playhead.
    @_spi(Benchmark) public var restoresPlaybackPosition: Bool

    /// Creates bounded playback and prefetch settings using the supplied tuning values.
    @_spi(Benchmark) public init(strategy: HMPlaybackStrategy, poolSize: Int = 2,
                prefetch: HMPrefetchPolicy = HMPrefetchPolicy(), cacheCapacityBytes: Int = 128_000_000,
                steadyBufferDuration: TimeInterval = 10, startupPeakBitRate: Double = 1_600_000,
                steadyPeakBitRate: Double = 0, startupBitRateWindow: TimeInterval = 4,
                loops: Bool = true, startsMuted: Bool = false, managesAudioSession: Bool = true,
                restoresPlaybackPosition: Bool = true, lowWaterMark: Int = 3, playlistTTL: TimeInterval = 30) {
        self.lowWaterMark = max(0, lowWaterMark)
        self.playlistTTL = playlistTTL.isFinite ? max(0, playlistTTL) : 30
        self.strategy = strategy; self.poolSize = max(1, min(4, poolSize)); self.prefetch = prefetch
        self.cacheCapacityBytes = max(0, cacheCapacityBytes)
        self.steadyBufferDuration = steadyBufferDuration; self.startupPeakBitRate = startupPeakBitRate
        self.steadyPeakBitRate = steadyPeakBitRate; self.startupBitRateWindow = startupBitRateWindow
        self.loops = loops; self.startsMuted = startsMuted; self.managesAudioSession = managesAudioSession
        self.restoresPlaybackPosition = restoresPlaybackPosition
    }
    /// Creates stable partner settings. Start with default, instantStart or highQuality, then adjust these budgets.
    public init(poolSize: Int = 2, prefetch: HMPrefetchPolicy = HMPrefetchPolicy(),
                cacheCapacityBytes: Int = 128_000_000, startupPeakBitRate: Double = 1_600_000,
                playlistTTL: TimeInterval = 30) {
        self.init(strategy: .S3, poolSize: poolSize, prefetch: prefetch, cacheCapacityBytes: cacheCapacityBytes,
                  startupPeakBitRate: startupPeakBitRate, playlistTTL: playlistTTL)
    }
    /// Creates the settings for one benchmark strategy.
    @_spi(Benchmark) public static func preset(_ strategy: HMPlaybackStrategy) -> Self {
        switch strategy {
        case .S0: return Self(strategy: strategy, poolSize: 1, prefetch: .off)
        case .S1: return Self(strategy: strategy, poolSize: 1)
        case .S2: return Self(strategy: strategy, poolSize: 4, prefetch: .balanced)
        case .S3: return Self()
        }
    }
    /// Default two-player hybrid settings.
    public static let `default` = HMPlayerConfiguration()
    /// Preset favouring a smaller startup rendition.
    public static let instantStart = HMPlayerConfiguration(strategy: .S3, steadyBufferDuration: 8, startupPeakBitRate: 900_000, startupBitRateWindow: 3)
    /// Preset with an unrestricted startup bitrate and longer buffer.
    public static let highQuality = HMPlayerConfiguration(strategy: .S3, steadyBufferDuration: 20, startupPeakBitRate: 0)
    /// Stable, complete serialized configuration; also hashed in the run header.
    @_spi(Benchmark) public var fingerprint: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(data: (try? encoder.encode(benchmarkRecord)) ?? Data(), encoding: .utf8) ?? "{}"
    }
    var warmOffsets: [Int] {
        let count = max(0, min(4, poolSize) - 1)
        if strategy == .S2 { return Array(prefetch.windowOffsets.prefix(count)) }
        if strategy == .S3 { return Array((1...max(1, count)).prefix(count)) }
        return []
    }
}

// Swift exposes an SPI-extension conformance through binary imports. Keep
// Codable on a separate SPI type so the partner value has no wire contract.
@_spi(Benchmark) public extension HMPlayerConfiguration {
    /// Codable bookkeeping value used only by benchmark tools.
    var benchmarkRecord: BenchmarkRecord { BenchmarkRecord(self) }

    /// Complete experimental configuration serialization, excluded from partner imports.
    struct BenchmarkRecord: Codable, Sendable {
        private let lowWaterMark: Int
        private let playlistTTL: TimeInterval
        private let volatileSigningQueryParameters: [String]
        private let strategy: HMPlaybackStrategy
        private let poolSize: Int
        private let prefetch: PolicyRecord
        private let cacheCapacityBytes: Int
        private let steadyBufferDuration: TimeInterval
        private let startupPeakBitRate: Double
        private let steadyPeakBitRate: Double
        private let startupBitRateWindow: TimeInterval
        private let loops: Bool
        private let startsMuted: Bool
        private let managesAudioSession: Bool
        private let restoresPlaybackPosition: Bool
        fileprivate init(_ c: HMPlayerConfiguration) {
            lowWaterMark = c.lowWaterMark; playlistTTL = c.playlistTTL
            volatileSigningQueryParameters = c.volatileSigningQueryParameters; strategy = c.strategy
            poolSize = c.poolSize; prefetch = PolicyRecord(c.prefetch); cacheCapacityBytes = c.cacheCapacityBytes
            steadyBufferDuration = c.steadyBufferDuration; startupPeakBitRate = c.startupPeakBitRate
            steadyPeakBitRate = c.steadyPeakBitRate; startupBitRateWindow = c.startupBitRateWindow
            loops = c.loops; startsMuted = c.startsMuted; managesAudioSession = c.managesAudioSession
            restoresPlaybackPosition = c.restoresPlaybackPosition
        }
        /// Restores the experimental configuration recorded by a benchmark.
        public var configuration: HMPlayerConfiguration {
            var c = HMPlayerConfiguration(strategy: strategy, poolSize: poolSize, prefetch: prefetch.policy,
                cacheCapacityBytes: cacheCapacityBytes, steadyBufferDuration: steadyBufferDuration,
                startupPeakBitRate: startupPeakBitRate, steadyPeakBitRate: steadyPeakBitRate,
                startupBitRateWindow: startupBitRateWindow, loops: loops, startsMuted: startsMuted,
                managesAudioSession: managesAudioSession, restoresPlaybackPosition: restoresPlaybackPosition,
                lowWaterMark: lowWaterMark, playlistTTL: playlistTTL)
            c.volatileSigningQueryParameters = volatileSigningQueryParameters
            return c
        }
        private struct PolicyRecord: Codable, Sendable {
            let ahead: Int, behind: Int
            let warmBufferDuration: TimeInterval
            let bytesPerItem: Int
            let secondsPerItem: TimeInterval?
            let startThreshold: TimeInterval
            init(_ p: HMPrefetchPolicy) {
                ahead = p.ahead; behind = p.behind; warmBufferDuration = p.warmBufferDuration
                bytesPerItem = p.bytesPerItem; secondsPerItem = p.secondsPerItem; startThreshold = p.startThreshold
            }
            var policy: HMPrefetchPolicy {
                HMPrefetchPolicy(ahead: ahead, behind: behind, warmBufferDuration: warmBufferDuration,
                    bytesPerItem: bytesPerItem, secondsPerItem: secondsPerItem, startThreshold: startThreshold)
            }
        }
    }
}
