import Foundation

/// Normalised playback telemetry. Deliberately modelled on the union of what
/// Mux Data, Conviva and Amplitude-style back ends expect, so a sink is a thin
/// mapping layer rather than a reimplementation.
public struct HMPlaybackEvent: Sendable, Identifiable {

    /// Categories of playback telemetry.
    public enum Kind: String, Sendable, CaseIterable {
        /// A view (one item impression) began. Mux: `videochange` / new view.
        case viewStart
        /// The viewer left the item. Carries watch time in `metrics`.
        case viewEnd
        /// Player asked the network for the asset.
        case loadStart
        /// First frame rendered. `metrics["ttff_ms"]` is the money number.
        case firstFrame
        /// Playback was requested.
        case play
        /// Playback is advancing.
        case playing
        /// Playback was paused.
        case pause
        /// A seek began.
        case seeking
        /// A seek completed.
        case seeked
        /// A playback stall began.
        case rebufferStart
        /// A playback stall ended.
        case rebufferEnd
        /// The selected HLS rendition changed.
        case variantChanged
        /// The VOD reached its end.
        case ended
        /// Playback failed.
        case error
        /// Emitted when the SDK warms an item that is not yet on screen.
        case preloadStart
        /// Prepared media became ready.
        case preloadReady
        /// A pooled `AVPlayer` was recycled onto a different item.
        case playerRecycled
        /// One response's network or cache byte totals.
        @_spi(Benchmark) case transfer
        /// Speculative download exhausted its retries.
        @_spi(Benchmark) case prefetchError
        /// Playback transport failed.
        case transportError
        /// First ten seconds of activation telemetry.
        @_spi(Benchmark) case startupSummary
        /// Benchmark session completed, including wasted speculative bytes.
        @_spi(Benchmark) case runEnd
    }

    /// Stable identity for this value.
    public let id = UUID()
    /// Event category.
    public let kind: Kind
    /// App-chosen playlist item ID.
    public let itemID: String
    /// Occurrence time on the system-uptime clock, in seconds.
    public let monotonicTime: TimeInterval
    /// Wall-clock occurrence time.
    public let timestamp: Date
    /// Player position when the event fired, seconds.
    public let position: TimeInterval
    /// Numeric payload (durations in ms, bitrates in bps, counts).
    public let metrics: [String: Double]
    /// String payload (variant URL, error message, custom dimensions).
    public let properties: [String: String]

    /// Creates telemetry with explicit occurrence clocks and optional payloads.
    public init(
        kind: Kind,
        itemID: String,
        timestamp: Date = Date(),
        monotonicTime: TimeInterval = ProcessInfo.processInfo.systemUptime,
        position: TimeInterval = 0,
        metrics: [String: Double] = [:],
        properties: [String: String] = [:]
    ) {
        self.kind = kind
        self.itemID = itemID
        self.timestamp = timestamp
        self.monotonicTime = monotonicTime
        self.position = position
        self.metrics = metrics
        self.properties = properties
    }
}

extension HMPlaybackEvent: CustomStringConvertible {
    /// Readable telemetry description with sorted payload keys.
    public var description: String {
        var parts = ["\(kind.rawValue) item=\(itemID)"]
        if position > 0 { parts.append(String(format: "t=%.2fs", position)) }
        for (key, value) in metrics.sorted(by: { $0.key < $1.key }) {
            parts.append("\(key)=\(String(format: "%.0f", value))")
        }
        for (key, value) in properties.sorted(by: { $0.key < $1.key }) {
            parts.append("\(key)=\(value)")
        }
        return parts.joined(separator: " ")
    }
}
