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
///
/// Use from any task; mutate only an exclusively owned value.
public struct HMPrefetchPolicy: Sendable, Equatable {
    /// Number of following entries in the data window, bounded to 0...8.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public var ahead: Int
    /// Number of preceding entries in the data window, bounded to 0...8.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public var behind: Int
    /// Native player buffer target for prepared neighbours, in seconds.
    @_spi(Benchmark) public var warmBufferDuration: TimeInterval
    /// Maximum speculative bytes per entry, bounded by maximumBytesPerItem.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public var bytesPerItem: Int
    /// Optional media-time budget; MP4 estimates bytes from duration/file size,
    /// HLS selects whole segments up to this duration, always bounded by bytes.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public var secondsPerItem: TimeInterval?
    /// Current buffered seconds required before speculative media work starts.
    @_spi(Benchmark) public var startThreshold: TimeInterval

    /// Creates bounded playback and prefetch settings using the supplied tuning values.
    @_spi(Benchmark) public init(ahead: Int = 3, behind: Int = 1, warmBufferDuration: TimeInterval,
                bytesPerItem: Int = 8 * 1024 * 1024, secondsPerItem: TimeInterval? = 4,
                startThreshold: TimeInterval = 3) {
        self.ahead = max(0, min(8, ahead)); self.behind = max(0, min(8, behind))
        self.warmBufferDuration = warmBufferDuration
        self.bytesPerItem = max(0, min(Self.maximumBytesPerItem, bytesPerItem)); self.secondsPerItem = secondsPerItem
        self.startThreshold = startThreshold
    }
    /// Creates a fixed data window and bounded per-item media budgets.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public init(ahead: Int = 3, behind: Int = 1, bytesPerItem: Int = 8 * 1024 * 1024, secondsPerItem: TimeInterval? = 4) {
        self.init(ahead: ahead, behind: behind, warmBufferDuration: 3, bytesPerItem: bytesPerItem, secondsPerItem: secondsPerItem)
    }
    /// Hard upper bound of 8 MiB for speculative bytes per entry.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public static let maximumBytesPerItem = 8 * 1024 * 1024
    /// Disables speculative fetching.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public static let off = HMPrefetchPolicy(ahead: 0, behind: 0, warmBufferDuration: 0, bytesPerItem: 0, secondsPerItem: 0)
    /// Prefetches only the next entry.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public static let nextOnly = HMPrefetchPolicy(ahead: 1, behind: 0)
    /// Prefetches two ahead and one behind.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public static let balanced = HMPrefetchPolicy(ahead: 2, behind: 1)
    /// Prefetches three ahead and two behind, with a five-second warm buffer.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public static let aggressive = HMPrefetchPolicy(ahead: 3, behind: 2, warmBufferDuration: 5)
    var windowOffsets: [Int] {
        let a = max(0, min(8, ahead)), b = max(0, min(8, behind))
        guard max(a, b) > 0 else { return [] }
        return (1...max(a, b)).flatMap { d in
            (d <= a ? [d] : []) + (d <= b ? [-d] : [])
        }
    }
}

/// Behavior after URL resolution exhausts retries or native media playback fails.
///
/// Use from any task; mutate only an exclusively owned value.
public enum HMFailedItemPolicy: String, Sendable {
    /// Advance to the next nonfailed entry, then search backwards; idle if none remain.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case skip
    /// Keep the failed entry current until the app or viewer navigates or retries.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case stay
}

/// Behavior when a playlist edit removes the current entry.
/// Use from any task; this is a Sendable value.
public enum HMRemovedCurrentPolicy: String, Sendable, Equatable {
    /// Select the next survivor, then previous; idle if none remain. The default.
    case advanceNow
    /// Retain current until its next natural end, suppress looping, then remove and advance.
    /// A swipe away removes it immediately. Other removals apply immediately.
    /// Failed, failure-idle or already-ended current entries advance immediately.
    /// Reconciliation with no upcoming entries goes idle instead of replaying history.
    case finishThenAdvance
}

/// When a feed swipe activates its destination. Use from any task.
public enum HMActivationTrigger: String, Sendable, CaseIterable {
    /// Activate at finger lift only when UIKit supplies the final aligned target; otherwise wait for settle.
    case lift
    /// Always wait until paging finishes.
    case settle
}

/// Playback, paging and cache settings for an HMPlayer.
///
/// Use from any task; mutate only an exclusively owned value.
public struct HMPlayerConfiguration: Sendable {
    /// Ad decision deadline in seconds. Default 1; invalid values use 1, bounded to 0.05...10.
    public var adDecisionTimeout: TimeInterval = 1
    /// URL-ad startup deadline, default 5 seconds; invalid values use 5, bounded to 0.1...30.
    public var adLoadTimeout: TimeInterval = 5
    /// Maximum accepted break wall time, default 120 seconds; finite values clamped to 0.1...3600.
    public var adBreakMaxDuration: TimeInterval = 120
    /// Allowed playing time without media progress, default 10 seconds; finite values clamped to 0.1...120.
    /// Suspended while playback is disallowed. Nonfinite values use the default.
    public var adNoProgressTimeout: TimeInterval = 10
    /// Allow vertical paging to cancel a pre-roll. Companion units never change this flag.
    public var allowsSwipeDuringAds = true
    /// Rendering default. Automatic preserves fill for matching vertical media and fits landscape media.
    public var presentation: HMVideoPresentation = .automatic
    /// Relative aspect difference permitted by automatic fill; default 25% accommodates safe-area differences.
    public var aspectRatioTolerance: Double = 0.25
    /// Bar color for fitWithColor.
    public var backdropColor: HMVideoBackdropColor = .black
    /// Opt in to entering landscape fullscreen and returning inline on portrait device rotation.
    public var followsDeviceRotation: Bool = false
    /// Ask the playlist source for more when this many entries remain after current.
    @_spi(Benchmark) public var lowWaterMark: Int = 3
    /// Memory-only HLS playlist freshness, in seconds.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public var playlistTTL: TimeInterval = 30
    /// Exact query parameter names to remove from cache and playback identity. Empty is safe by default.
    public var volatileSigningQueryParameters: [String] = []
    /// Benchmark playback strategy; S3 is the default hybrid.
    @_spi(Benchmark) public var strategy: HMPlaybackStrategy
    /// Native player count, bounded to 1...4 by the engine.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public var poolSize: Int
    /// App maximum prefetch window and media budgets (fixed when adaptive is false).
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public var prefetch: HMPrefetchPolicy
    /// Adapt within app limits using measured performance; false uses fixed numbers.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public var adaptive: Bool = false
    /// Activate at a known final paging target on lift, with a settled fallback for unknown targets.
    public var activationTrigger: HMActivationTrigger = .lift
    /// All thresholds for the default measured-performance policy.
    @_spi(Benchmark) public var adaptiveThresholds = HMAdaptivePrefetchThresholds()
    /// Maximum simultaneous prefix downloads, bounded to 0...4; default serial.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public var maxPrefetchConcurrency: Int = 1
    /// URL/poster-only forward resolution horizon, bounded to 0...32.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public var resolveAhead: Int = 8
    /// Minimum cached payload for a tier-2 arrival hit; avoids counting tiny AVPlayer probes.
    /// Defaults to 32 KiB, bounded by a positive app per-item prefix budget.
    @_spi(Benchmark) public var minimumCachedStartBytes: Int = 32 * 1024
    /// Hard disk media cache cap, in bytes.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public var cacheCapacityBytes: Int
    /// Current player forward-buffer target in seconds.
    @_spi(Benchmark) public var steadyBufferDuration: TimeInterval
    /// Initial bitrate ceiling in bits per second; zero leaves it unrestricted.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public var startupPeakBitRate: Double
    /// Bitrate ceiling after startup in bits per second; zero leaves it unrestricted.
    @_spi(Benchmark) public var steadyPeakBitRate: Double
    /// Seconds after activation before lifting the startup ceiling.
    @_spi(Benchmark) public var startupBitRateWindow: TimeInterval
    /// Terminal item behavior. Skipping waits for dragging, scrubbing and page motion to finish.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public var failedItemPolicy: HMFailedItemPolicy = .skip
    /// Removal behavior for `remove(ids:)` and a ranked refresh missing current.
    /// Access from any task; mutate only an exclusively owned value.
    public var removedCurrentPolicy: HMRemovedCurrentPolicy = .advanceNow
    /// Whether an item loops when it reaches its end.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public var loops: Bool
    /// Initial global mute state.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public var startsMuted: Bool
    /// Whether the SDK configures, activates and deactivates the app audio session (default true).
    /// Set false before presenting the player when the host app owns AVAudioSession; teardown also leaves it alone.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public var managesAudioSession: Bool
    /// Allows playback while backgrounded. The host must also enable its audio background mode.
    public var allowsBackgroundAudio = false
    /// Whether revisiting an entry restores its last playhead.
    @_spi(Benchmark) public var restoresPlaybackPosition: Bool

    /// Creates bounded playback and prefetch settings using the supplied tuning values.
    @_spi(Benchmark) public init(strategy: HMPlaybackStrategy, poolSize: Int = 2,
                prefetch: HMPrefetchPolicy = HMPrefetchPolicy(), cacheCapacityBytes: Int = 128_000_000,
                steadyBufferDuration: TimeInterval = 10, startupPeakBitRate: Double = 1_600_000,
                steadyPeakBitRate: Double = 0, startupBitRateWindow: TimeInterval = 4,
                loops: Bool = true, startsMuted: Bool = false, managesAudioSession: Bool = true,
                restoresPlaybackPosition: Bool = true, lowWaterMark: Int = 3, playlistTTL: TimeInterval = 30, adaptive: Bool = false, failedItemPolicy: HMFailedItemPolicy = .skip) {
        self.failedItemPolicy = failedItemPolicy
        self.adaptive = adaptive
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
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public init(poolSize: Int = 2, prefetch: HMPrefetchPolicy = HMPrefetchPolicy(),
                cacheCapacityBytes: Int = 128_000_000, startupPeakBitRate: Double = 1_600_000,
                playlistTTL: TimeInterval = 30, loops: Bool = true, startsMuted: Bool = false,
                managesAudioSession: Bool = true, adaptive: Bool = false, failedItemPolicy: HMFailedItemPolicy = .skip) {
        self.init(strategy: .S3, poolSize: poolSize, prefetch: prefetch, cacheCapacityBytes: cacheCapacityBytes,
                  startupPeakBitRate: startupPeakBitRate, loops: loops, startsMuted: startsMuted,
                  managesAudioSession: managesAudioSession, playlistTTL: playlistTTL, adaptive: adaptive, failedItemPolicy: failedItemPolicy)
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
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public static let `default` = HMPlayerConfiguration()
    /// Preset favouring a smaller startup rendition.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public static let instantStart = HMPlayerConfiguration(strategy: .S3, steadyBufferDuration: 8, startupPeakBitRate: 900_000, startupBitRateWindow: 3)
    /// Preset with an unrestricted startup bitrate and longer buffer.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public static let highQuality = HMPlayerConfiguration(strategy: .S3, steadyBufferDuration: 20, startupPeakBitRate: 0)
    /// Stable, complete serialized configuration; also hashed in the run header.
    @_spi(Benchmark) public var fingerprint: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(data: (try? encoder.encode(benchmarkRecord)) ?? Data(), encoding: .utf8) ?? "{}"
    }
    var warmOffsets: [Int] {
        let count = max(0, min(4, poolSize) - 1)
        if strategy == .S2 { return Array(prefetch.windowOffsets.prefix(count)) }
        if strategy == .S3 { return Array([1, -1, 2].filter { $0 > 0 ? $0 <= prefetch.ahead : -$0 <= prefetch.behind }.prefix(count)) }
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
        private let adDecisionTimeout: TimeInterval?
        private let adLoadTimeout: TimeInterval?
        private let adBreakMaxDuration: TimeInterval?
        private let adNoProgressTimeout: TimeInterval?
        private let allowsSwipeDuringAds: Bool?
        private let presentation: HMVideoPresentation?
        private let aspectRatioTolerance: Double?
        private let backdropColor: HMVideoBackdropColor?
        private let followsDeviceRotation: Bool?
        private let failedItemPolicy: FailedItemPolicyRecord?
        private let removedCurrentPolicy: String?
        private let adaptive: Bool
        private let adaptiveThresholds: HMAdaptivePrefetchThresholds
        private let maxPrefetchConcurrency: Int
        private let resolveAhead: Int
        private let minimumCachedStartBytes: Int
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
        private let allowsBackgroundAudio: Bool?
        private let restoresPlaybackPosition: Bool
        private let activationTrigger: String?
        fileprivate init(_ c: HMPlayerConfiguration) {
            adBreakMaxDuration = c.adBreakMaxDuration; adNoProgressTimeout = c.adNoProgressTimeout
            adDecisionTimeout = c.adDecisionTimeout; adLoadTimeout = c.adLoadTimeout; allowsSwipeDuringAds = c.allowsSwipeDuringAds
            presentation = c.presentation; aspectRatioTolerance = c.aspectRatioTolerance
            backdropColor = c.backdropColor; followsDeviceRotation = c.followsDeviceRotation
            failedItemPolicy = c.failedItemPolicy == .skip ? .skip : .stay
            removedCurrentPolicy = c.removedCurrentPolicy.rawValue
            adaptive = c.adaptive; adaptiveThresholds = c.adaptiveThresholds
            maxPrefetchConcurrency = c.maxPrefetchConcurrency; resolveAhead = c.resolveAhead; minimumCachedStartBytes = c.minimumCachedStartBytes
            lowWaterMark = c.lowWaterMark; playlistTTL = c.playlistTTL
            volatileSigningQueryParameters = c.volatileSigningQueryParameters; strategy = c.strategy
            poolSize = c.poolSize; prefetch = PolicyRecord(c.prefetch); cacheCapacityBytes = c.cacheCapacityBytes
            steadyBufferDuration = c.steadyBufferDuration; startupPeakBitRate = c.startupPeakBitRate
            steadyPeakBitRate = c.steadyPeakBitRate; startupBitRateWindow = c.startupBitRateWindow
            loops = c.loops; startsMuted = c.startsMuted; managesAudioSession = c.managesAudioSession
            restoresPlaybackPosition = c.restoresPlaybackPosition
            activationTrigger = c.activationTrigger.rawValue
            allowsBackgroundAudio = c.allowsBackgroundAudio
        }
        /// Restores the experimental configuration recorded by a benchmark.
        public var configuration: HMPlayerConfiguration {
            var c = HMPlayerConfiguration(strategy: strategy, poolSize: poolSize, prefetch: prefetch.policy,
                cacheCapacityBytes: cacheCapacityBytes, steadyBufferDuration: steadyBufferDuration,
                startupPeakBitRate: startupPeakBitRate, steadyPeakBitRate: steadyPeakBitRate,
                startupBitRateWindow: startupBitRateWindow, loops: loops, startsMuted: startsMuted,
                managesAudioSession: managesAudioSession, restoresPlaybackPosition: restoresPlaybackPosition,
                lowWaterMark: lowWaterMark, playlistTTL: playlistTTL)
            c.allowsBackgroundAudio = allowsBackgroundAudio ?? false
            c.adBreakMaxDuration = adBreakMaxDuration ?? 120; c.adNoProgressTimeout = adNoProgressTimeout ?? 10
            c.adDecisionTimeout = adDecisionTimeout ?? 1; c.adLoadTimeout = adLoadTimeout ?? 5; c.allowsSwipeDuringAds = allowsSwipeDuringAds ?? true
            c.presentation = presentation ?? .automatic; c.aspectRatioTolerance = aspectRatioTolerance ?? 0.25
            c.backdropColor = backdropColor ?? .black; c.followsDeviceRotation = followsDeviceRotation ?? false
            c.failedItemPolicy = failedItemPolicy == .stay ? .stay : .skip
            c.removedCurrentPolicy = removedCurrentPolicy.flatMap(HMRemovedCurrentPolicy.init(rawValue:)) ?? .advanceNow
            c.adaptive = adaptive; c.adaptiveThresholds = adaptiveThresholds
            c.maxPrefetchConcurrency = maxPrefetchConcurrency; c.resolveAhead = resolveAhead; c.minimumCachedStartBytes = minimumCachedStartBytes
            c.volatileSigningQueryParameters = volatileSigningQueryParameters
            c.activationTrigger = activationTrigger.flatMap(HMActivationTrigger.init(rawValue:)) ?? .settle
            return c
        }
        private enum FailedItemPolicyRecord: String, Codable { case skip, stay }
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
