import Foundation

/// Turns a live stream's noisy seekable range into one a scrubber can render.
///
/// `AVPlayerItem.seekableTimeRanges` is derived from the manifest, and two
/// separate artefacts of that make a naive playhead unusable:
///
/// - The **edge** only moves when a refresh lands, in jumps of one target
///   duration, while `currentTime` advances continuously. Subtracting one from
///   the other produces a sawtooth.
/// - The **depth** toggles by a segment as the window is trimmed, which rescales
///   the whole rail underneath a playhead that hasn't moved.
///
/// Both show up as the playhead sliding backwards every couple of seconds while
/// the video plays on.
///
/// So: extrapolate the edge with the wall clock, since that is what it
/// physically does, and take the depth as a running maximum with a slow decay.
/// Averaging the depth does not work — the trimming pattern is a slow square
/// wave, and any low-pass fast enough to track a real change still follows it.
/// A maximum reads the DVR depth the stream is actually offering, and the decay
/// keeps it honest if that depth genuinely shrinks.
struct HMLiveWindowTracker {

    struct Window: Equatable {
        var start: TimeInterval
        var edge: TimeInterval
        var depth: TimeInterval { max(0, edge - start) }
    }

    /// How far the edge may lead the manifest before it is reeled back in.
    /// Bounds any drift between the media and wall clocks.
    var maximumLead: TimeInterval = 4
    /// A measured edge this far behind the estimate means the stream restarted
    /// or the player was recycled, rather than a slow manifest.
    var resyncThreshold: TimeInterval = 5
    /// Seconds of depth surrendered per second when the manifest stops offering
    /// it. Slow enough that segment-level trimming never shows, fast enough that
    /// a genuine DVR change is followed within about a minute.
    var depthDecayRate: Double = 0.05

    private var edge: TimeInterval?
    private var depth: TimeInterval?
    private var sampledAt: TimeInterval?

    /// - Parameters:
    ///   - measuredStart: lower bound of the current seekable range.
    ///   - measuredEdge: upper bound of the current seekable range.
    ///   - now: monotonic clock reading, in seconds.
    mutating func update(
        measuredStart: TimeInterval,
        measuredEdge: TimeInterval,
        now: TimeInterval
    ) -> Window {
        let measuredDepth = max(0, measuredEdge - measuredStart)
        defer { sampledAt = now }

        guard let edge, let depth, let sampledAt, measuredEdge > edge - resyncThreshold else {
            self.edge = measuredEdge
            self.depth = measuredDepth
            return Window(start: measuredEdge - measuredDepth, edge: measuredEdge)
        }

        let elapsed = max(0, now - sampledAt)
        let extrapolated = edge + elapsed
        let nextEdge = min(max(extrapolated, measuredEdge), measuredEdge + maximumLead)
        let nextDepth = max(measuredDepth, depth - depthDecayRate * elapsed)

        self.edge = nextEdge
        self.depth = nextDepth
        return Window(start: nextEdge - nextDepth, edge: nextEdge)
    }

    mutating func reset() {
        edge = nil
        depth = nil
        sampledAt = nil
    }
}
