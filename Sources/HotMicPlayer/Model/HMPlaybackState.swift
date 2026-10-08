import Foundation

/// Coarse lifecycle state of one item's playback.
public enum HMPlaybackState: String, Sendable {
    /// No `AVPlayerItem` attached yet.
    case idle
    /// Item attached, asset loading / first segments downloading.
    case loading
    /// Enough buffered to start, but not playing (warmed neighbour, or paused).
    case ready
    case playing
    case paused
    /// Playback started but the buffer drained.
    case buffering
    case failed
}

/// Immutable snapshot handed to overlay views. Cheap to diff, safe to pass around.
public struct HMPlaybackSnapshot: Sendable, Equatable {
    public var state: HMPlaybackState = .idle
    public var currentTime: TimeInterval = 0
    /// End of the seekable range. For VOD this is the asset duration; for a
    /// live stream it is the live edge and it advances continuously.
    public var duration: TimeInterval = 0
    /// Start of the seekable range. Non-zero on live streams with a DVR window.
    public var seekableStart: TimeInterval = 0
    /// True when the player reports an indefinite duration, i.e. a live edge.
    public var isLive: Bool = false
    public var bufferedAhead: TimeInterval = 0
    public var isMuted: Bool = false
    /// Observed bitrate of the current HLS variant, bits/sec. `0` when unknown.
    public var indicatedBitrate: Double = 0
    /// Time from "make this visible" to the first rendered frame, in seconds.
    public var timeToFirstFrame: TimeInterval?
    public var stallCount: Int = 0
    public var totalStallDuration: TimeInterval = 0
    /// True while this item was preloaded ahead of being shown.
    public var wasPreloaded: Bool = false
    public var isFrameReady: Bool = false
    public var activationID: String = ""
    public var errorDescription: String?

    /// Position within the seekable window, not the absolute asset. Keeps the
    /// scrubber correct for DVR, where the window slides forward under you.
    public var progress: Double {
        let span = duration - seekableStart
        guard span > 0 else { return 0 }
        return min(1, max(0, (currentTime - seekableStart) / span))
    }

    /// Seconds of seekable content — what a scrubber should label itself with.
    public var seekableDuration: TimeInterval { max(0, duration - seekableStart) }

    public init() {}
}
