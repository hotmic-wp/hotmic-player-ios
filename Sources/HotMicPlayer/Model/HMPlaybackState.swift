import Foundation

/// Coarse lifecycle state of one item's playback.
public enum HMPlaybackState: String, Sendable {
    /// No `AVPlayerItem` attached yet.
    case idle
    /// Item attached, asset loading / first segments downloading.
    case loading
    /// Enough buffered to start, but not playing (warmed neighbour, or paused).
    case ready
    /// Playback is advancing.
    case playing
    /// Playback is paused.
    case paused
    /// Playback started but the buffer drained.
    case buffering
    /// Playback failed.
    case failed
}

/// Immutable snapshot handed to overlay views. Cheap to diff, safe to pass around.
public struct HMPlaybackSnapshot: Sendable, Equatable {
    /// Coarse playback lifecycle state.
    public internal(set) var state: HMPlaybackState = .idle
    /// Current VOD playhead in seconds.
    public internal(set) var currentTime: TimeInterval = 0
    /// End of the seekable range. For VOD this is the asset duration; for a
    /// live stream it is the live edge and it advances continuously.
    public internal(set) var duration: TimeInterval = 0
    /// Start of the seekable range. Non-zero on live streams with a DVR window.
    public internal(set) var seekableStart: TimeInterval = 0
    /// True when the player reports an indefinite duration, i.e. a live edge.
    public internal(set) var isLive: Bool = false
    /// Buffered media ahead of the playhead, in seconds.
    public internal(set) var bufferedAhead: TimeInterval = 0
    /// Whether audio is muted.
    public internal(set) var isMuted: Bool = false
    /// Observed bitrate of the current HLS variant, bits/sec. `0` when unknown.
    public internal(set) var indicatedBitrate: Double = 0
    /// Time from "make this visible" to the first rendered frame, in seconds.
    public internal(set) var timeToFirstFrame: TimeInterval?
    /// Number of stalls since the latest activation.
    public internal(set) var stallCount: Int = 0
    /// Accumulated stall time in seconds since activation.
    public internal(set) var totalStallDuration: TimeInterval = 0
    /// True while this item was preloaded ahead of being shown.
    public internal(set) var wasPreloaded: Bool = false
    /// Readiness measured when this entry became current.
    public internal(set) var readinessTier: HMReadinessTier = .cold
    /// Whether a decoded frame is ready for display.
    @_spi(Benchmark) public internal(set) var isFrameReady: Bool = false
    /// Unique identifier for the current view activation; empty before activation.
    @_spi(Benchmark) public internal(set) var activationID: String = ""
    /// Latest decoder failure description, if any.
    public internal(set) var errorDescription: String?

    /// Position within the seekable window, not the absolute asset. Keeps the
    /// scrubber correct for DVR, where the window slides forward under you.
    public var progress: Double {
        let span = duration - seekableStart
        guard span > 0 else { return 0 }
        return min(1, max(0, (currentTime - seekableStart) / span))
    }

    /// Seconds of seekable content — what a scrubber should label itself with.
    public var seekableDuration: TimeInterval { max(0, duration - seekableStart) }

    /// Creates an idle playback snapshot.
    public init() {}
}
