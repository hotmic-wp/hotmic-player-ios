import Foundation

/// Coarse lifecycle state of one item's playback.
///
/// Use from any task; mutate only an exclusively owned value.
public enum HMPlaybackState: String, Sendable {
    /// No `AVPlayerItem` attached yet.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case idle
    /// Item attached, asset loading / first segments downloading.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case loading
    /// Enough buffered to start, but not playing (warmed neighbour, or paused).
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case ready
    /// Playback is advancing.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case playing
    /// Playback is paused.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case paused
    /// Playback started but the buffer drained.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case buffering
    /// Playback failed.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case failed
}

/// Immutable snapshot handed to overlay views. Cheap to diff, safe to pass around.
///
/// Use from any task; mutate only an exclusively owned value.
public struct HMPlaybackSnapshot: Sendable, Equatable {
    /// Coarse playback lifecycle state.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public internal(set) var state: HMPlaybackState = .idle
    /// Current VOD playhead in seconds.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public internal(set) var currentTime: TimeInterval = 0
    /// End of the seekable range. For VOD this is the asset duration; for a
    /// live stream it is the live edge and it advances continuously.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public internal(set) var duration: TimeInterval = 0
    /// Start of the seekable range. Non-zero on live streams with a DVR window.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public internal(set) var seekableStart: TimeInterval = 0
    /// True when the player reports an indefinite duration, i.e. a live edge.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public internal(set) var isLive: Bool = false
    /// Buffered media ahead of the playhead, in seconds.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public internal(set) var bufferedAhead: TimeInterval = 0
    /// Whether audio is muted.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public internal(set) var isMuted: Bool = false
    /// Observed bitrate of the current HLS variant, bits/sec. `0` when unknown.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public internal(set) var indicatedBitrate: Double = 0
    /// Time from "make this visible" to the first rendered frame, in seconds.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public internal(set) var timeToFirstFrame: TimeInterval?
    /// Number of stalls since the latest activation.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public internal(set) var stallCount: Int = 0
    /// Accumulated stall time in seconds since activation.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public internal(set) var totalStallDuration: TimeInterval = 0
    /// True while this item was preloaded ahead of being shown.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public internal(set) var wasPreloaded: Bool = false
    /// For active entries, readiness measured at activation, preserved through playback.
    /// For an inactive prepared entry, snapshot(for:) reports warmPlayer once a decoded frame
    /// is ready; otherwise resolved. Use warmPlayer for an upcoming entry's warm badge.
    /// Unprepared entries report cold; the unresolved current reports resolving.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public internal(set) var readinessTier: HMReadinessTier = .cold
    /// Whether a decoded frame is ready for display.
    @_spi(Benchmark) public internal(set) var isFrameReady: Bool = false
    /// Unique identifier for the current view activation; empty before activation.
    @_spi(Benchmark) public internal(set) var activationID: String = ""
    /// Latest decoder failure description, if any.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public internal(set) var errorDescription: String?

    /// Position within the seekable window, not the absolute asset. Keeps the
    /// scrubber correct for DVR, where the window slides forward under you.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public var progress: Double {
        let span = duration - seekableStart
        guard span > 0 else { return 0 }
        return min(1, max(0, (currentTime - seekableStart) / span))
    }

    /// Seconds of seekable content — what a scrubber should label itself with.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public var seekableDuration: TimeInterval { max(0, duration - seekableStart) }

    /// Creates an idle playback snapshot.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public init() {}
}
