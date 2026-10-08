import Foundation

public enum HMPlaybackStrategy: String, Sendable, Codable, CaseIterable {
    case S0, S1, S2, S3
    public var usesDataCache: Bool { self == .S1 || self == .S3 }
}

/// Nearest-first data window. S2 uses this same window for warm players.
public struct HMPrefetchPolicy: Sendable, Equatable, Codable {
    public var ahead: Int
    public var behind: Int
    public var warmBufferDuration: TimeInterval
    public var bytesPerItem: Int
    /// Optional media-time budget; MP4 estimates bytes from duration/file size,
    /// HLS selects whole segments up to this duration, always bounded by bytes.
    public var secondsPerItem: TimeInterval?
    public var startThreshold: TimeInterval

    public init(ahead: Int = 5, behind: Int = 1, warmBufferDuration: TimeInterval = 3,
                bytesPerItem: Int = 800_000, secondsPerItem: TimeInterval? = nil,
                startThreshold: TimeInterval = 3) {
        self.ahead = max(0, min(8, ahead)); self.behind = max(0, min(8, behind))
        self.warmBufferDuration = warmBufferDuration
        self.bytesPerItem = bytesPerItem; self.secondsPerItem = secondsPerItem
        self.startThreshold = startThreshold
    }
    public static let off = HMPrefetchPolicy(ahead: 0, behind: 0, warmBufferDuration: 0)
    public static let nextOnly = HMPrefetchPolicy(ahead: 1, behind: 0)
    public static let balanced = HMPrefetchPolicy(ahead: 2, behind: 1)
    public static let aggressive = HMPrefetchPolicy(ahead: 3, behind: 2, warmBufferDuration: 5)
    var windowOffsets: [Int] {
        let a = max(0, min(8, ahead)), b = max(0, min(8, behind))
        guard max(a, b) > 0 else { return [] }
        return (1...max(a, b)).flatMap { d in
            (d <= a ? [d] : []) + (d <= b ? [-d] : [])
        }
    }
}

public struct HMPlayerConfiguration: Sendable, Codable {
    public var strategy: HMPlaybackStrategy
    public var poolSize: Int
    public var prefetch: HMPrefetchPolicy
    public var cacheCapacityBytes: Int
    public var steadyBufferDuration: TimeInterval
    public var startupPeakBitRate: Double
    public var steadyPeakBitRate: Double
    public var startupBitRateWindow: TimeInterval
    public var loops: Bool
    public var startsMuted: Bool
    public var managesAudioSession: Bool
    public var restoresPlaybackPosition: Bool

    public init(strategy: HMPlaybackStrategy = .S3, poolSize: Int = 2,
                prefetch: HMPrefetchPolicy = HMPrefetchPolicy(), cacheCapacityBytes: Int = 128_000_000,
                steadyBufferDuration: TimeInterval = 10, startupPeakBitRate: Double = 1_600_000,
                steadyPeakBitRate: Double = 0, startupBitRateWindow: TimeInterval = 4,
                loops: Bool = true, startsMuted: Bool = false, managesAudioSession: Bool = true,
                restoresPlaybackPosition: Bool = true) {
        self.strategy = strategy; self.poolSize = max(1, min(4, poolSize)); self.prefetch = prefetch
        self.cacheCapacityBytes = max(0, cacheCapacityBytes)
        self.steadyBufferDuration = steadyBufferDuration; self.startupPeakBitRate = startupPeakBitRate
        self.steadyPeakBitRate = steadyPeakBitRate; self.startupBitRateWindow = startupBitRateWindow
        self.loops = loops; self.startsMuted = startsMuted; self.managesAudioSession = managesAudioSession
        self.restoresPlaybackPosition = restoresPlaybackPosition
    }
    public static func preset(_ strategy: HMPlaybackStrategy) -> Self {
        switch strategy {
        case .S0: return Self(strategy: strategy, poolSize: 1, prefetch: .off)
        case .S1: return Self(strategy: strategy, poolSize: 1)
        case .S2: return Self(strategy: strategy, poolSize: 4, prefetch: .balanced)
        case .S3: return Self()
        }
    }
    public static let `default` = HMPlayerConfiguration()
    public static let instantStart = HMPlayerConfiguration(steadyBufferDuration: 8, startupPeakBitRate: 900_000, startupBitRateWindow: 3)
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
