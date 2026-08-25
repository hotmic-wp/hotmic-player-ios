import Foundation

/// How aggressively the feed warms up neighbouring items.
public struct HMPrefetchPolicy: Sendable, Equatable {
    /// Number of items *below* the active one to warm.
    public var ahead: Int
    /// Number of items *above* the active one to keep warm (back-swipes are common).
    public var behind: Int
    /// Seconds of media each warmed item should buffer before we stop pushing.
    public var warmBufferDuration: TimeInterval

    public init(ahead: Int = 2, behind: Int = 1, warmBufferDuration: TimeInterval = 3) {
        self.ahead = ahead
        self.behind = behind
        self.warmBufferDuration = warmBufferDuration
    }

    /// No preloading at all — useful as an A/B baseline in the sample app.
    public static let off = HMPrefetchPolicy(ahead: 0, behind: 0, warmBufferDuration: 0)
    /// Warm only the very next item. Cheapest policy that still hides startup latency.
    public static let nextOnly = HMPrefetchPolicy(ahead: 1, behind: 0)
    public static let balanced = HMPrefetchPolicy(ahead: 2, behind: 1)
    public static let aggressive = HMPrefetchPolicy(ahead: 3, behind: 2, warmBufferDuration: 5)

    var windowOffsets: [Int] {
        guard ahead > 0 || behind > 0 else { return [] }
        // Interleave so the nearest neighbours are warmed first.
        var offsets: [Int] = []
        for distance in 1...max(ahead, behind) {
            if distance <= ahead { offsets.append(distance) }
            if distance <= behind { offsets.append(-distance) }
        }
        return offsets
    }
}

/// Tuning knobs for the whole feed. Every value has a sane default; the sample
/// app mutates these live so you can feel the difference.
public struct HMPlayerConfiguration: Sendable {

    /// Number of recycled `AVPlayer` instances. Must be >= 1 + prefetch window
    /// to avoid thrashing, but each one costs memory and a decoder session.
    public var poolSize: Int
    public var prefetch: HMPrefetchPolicy

    /// Buffer target once an item is on screen and playing. The target while an
    /// item is merely warmed lives on `prefetch.warmBufferDuration`.
    public var steadyBufferDuration: TimeInterval

    /// Bitrate ceiling applied for the first moments of playback so ABR picks a
    /// small first segment. `0` means "no cap". Lifted once playback is stable.
    public var startupPeakBitRate: Double
    /// Bitrate ceiling in steady state. `0` means "no cap".
    public var steadyPeakBitRate: Double
    /// How long we stay in the "startup" bitrate regime after playback begins.
    public var startupBitRateWindow: TimeInterval

    public var loops: Bool
    public var startsMuted: Bool
    /// When true the SDK configures `AVAudioSession` for `.playback` on start.
    public var managesAudioSession: Bool
    /// Resume an item where the viewer left it when they swipe back.
    public var restoresPlaybackPosition: Bool

    public init(
        poolSize: Int = 4,
        prefetch: HMPrefetchPolicy = .balanced,
        steadyBufferDuration: TimeInterval = 10,
        startupPeakBitRate: Double = 1_600_000,
        steadyPeakBitRate: Double = 0,
        startupBitRateWindow: TimeInterval = 4,
        loops: Bool = true,
        startsMuted: Bool = false,
        managesAudioSession: Bool = true,
        restoresPlaybackPosition: Bool = true
    ) {
        self.poolSize = poolSize
        self.prefetch = prefetch
        self.steadyBufferDuration = steadyBufferDuration
        self.startupPeakBitRate = startupPeakBitRate
        self.steadyPeakBitRate = steadyPeakBitRate
        self.startupBitRateWindow = startupBitRateWindow
        self.loops = loops
        self.startsMuted = startsMuted
        self.managesAudioSession = managesAudioSession
        self.restoresPlaybackPosition = restoresPlaybackPosition
    }

    public static let `default` = HMPlayerConfiguration()

    /// Lowest-latency preset: cap the first segment hard, keep buffers short.
    public static let instantStart = HMPlayerConfiguration(
        poolSize: 5,
        prefetch: .aggressive,
        steadyBufferDuration: 8,
        startupPeakBitRate: 900_000,
        startupBitRateWindow: 3
    )

    /// Quality-first preset: no bitrate caps, deeper buffers, less preloading.
    public static let highQuality = HMPlayerConfiguration(
        poolSize: 3,
        prefetch: .nextOnly,
        steadyBufferDuration: 20,
        startupPeakBitRate: 0,
        steadyPeakBitRate: 0
    )
}
