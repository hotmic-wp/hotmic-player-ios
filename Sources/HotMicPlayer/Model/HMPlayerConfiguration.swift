import Foundation

/// Benchmark strategies: direct, data cache, warm pool and hybrid.
public enum HMPlaybackStrategy: String, Sendable, Codable, CaseIterable {
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
public struct HMPrefetchPolicy: Sendable, Equatable, Codable {
    /// Number of following entries in the data window, bounded to 0...8.
    public var ahead: Int
    /// Number of preceding entries in the data window, bounded to 0...8.
    public var behind: Int
    /// Native player buffer target for prepared neighbours, in seconds.
    public var warmBufferDuration: TimeInterval
    /// Maximum speculative bytes per entry, bounded by maximumBytesPerItem.
    public var bytesPerItem: Int
    /// Optional media-time budget; MP4 estimates bytes from duration/file size,
    /// HLS selects whole segments up to this duration, always bounded by bytes.
    public var secondsPerItem: TimeInterval?
    /// Current buffered seconds required before speculative media work starts.
    public var startThreshold: TimeInterval

    /// Creates bounded playback and prefetch settings using the supplied tuning values.
    public init(ahead: Int = 5, behind: Int = 1, warmBufferDuration: TimeInterval = 3,
                bytesPerItem: Int = 800_000, secondsPerItem: TimeInterval? = nil,
                startThreshold: TimeInterval = 3) {
        self.ahead = max(0, min(8, ahead)); self.behind = max(0, min(8, behind))
        self.warmBufferDuration = warmBufferDuration
        self.bytesPerItem = max(0, min(Self.maximumBytesPerItem, bytesPerItem)); self.secondsPerItem = secondsPerItem
        self.startThreshold = startThreshold
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
public struct HMPlayerConfiguration: Sendable, Codable {
    /// Ask the playlist source for more when this many entries remain after current.
    public var lowWaterMark: Int = 3
    /// Memory-only HLS playlist freshness, in seconds.
    public var playlistTTL: TimeInterval = 30
    /// Exact query parameter names to remove from cache identity. Empty is safe by default.
    public var volatileSigningQueryParameters: [String] = []
    /// Benchmark playback strategy; S3 is the default hybrid.
    public var strategy: HMPlaybackStrategy
    /// Native player count, bounded to 1...4 by the engine.
    public var poolSize: Int
    /// Fixed prefetch window and media budgets.
    public var prefetch: HMPrefetchPolicy
    /// Hard disk media cache cap, in bytes.
    public var cacheCapacityBytes: Int
    /// Current player forward-buffer target in seconds.
    public var steadyBufferDuration: TimeInterval
    /// Initial bitrate ceiling in bits per second; zero leaves it unrestricted.
    public var startupPeakBitRate: Double
    /// Bitrate ceiling after startup in bits per second; zero leaves it unrestricted.
    public var steadyPeakBitRate: Double
    /// Seconds after activation before lifting the startup ceiling.
    public var startupBitRateWindow: TimeInterval
    /// Whether an item loops when it reaches its end.
    public var loops: Bool
    /// Initial global mute state.
    public var startsMuted: Bool
    /// Whether the SDK activates and deactivates the app audio session.
    public var managesAudioSession: Bool
    /// Whether revisiting an entry restores its last playhead.
    public var restoresPlaybackPosition: Bool

    /// Creates bounded playback and prefetch settings using the supplied tuning values.
    public init(strategy: HMPlaybackStrategy = .S3, poolSize: Int = 2,
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
    /// Creates the settings for one benchmark strategy.
    public static func preset(_ strategy: HMPlaybackStrategy) -> Self {
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
    public static let instantStart = HMPlayerConfiguration(steadyBufferDuration: 8, startupPeakBitRate: 900_000, startupBitRateWindow: 3)
    /// Preset with an unrestricted startup bitrate and longer buffer.
    public static let highQuality = HMPlayerConfiguration(steadyBufferDuration: 20, startupPeakBitRate: 0)
    /// Stable, complete serialized configuration; also hashed in the run header.
    public var fingerprint: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(data: (try? encoder.encode(self)) ?? Data(), encoding: .utf8) ?? "{}"
    }
    var warmOffsets: [Int] {
        let count = max(0, min(4, poolSize) - 1)
        if strategy == .S2 { return Array(prefetch.windowOffsets.prefix(count)) }
        if strategy == .S3 { return Array((1...max(1, count)).prefix(count)) }
        return []
    }
}
