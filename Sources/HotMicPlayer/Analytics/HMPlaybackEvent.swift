import Foundation

/// Normalised playback telemetry. Deliberately modelled on the union of what
/// Mux Data, Conviva and Amplitude-style back ends expect, so a sink is a thin
/// mapping layer rather than a reimplementation.
public struct HMPlaybackEvent: Sendable, Identifiable {

    public enum Kind: String, Sendable, CaseIterable {
        /// A view (one item impression) began. Mux: `videochange` / new view.
        case viewStart
        /// The viewer left the item. Carries watch time in `metrics`.
        case viewEnd
        /// Player asked the network for the asset.
        case loadStart
        /// First frame rendered. `metrics["ttff_ms"]` is the money number.
        case firstFrame
        case play
        case playing
        case pause
        case seeking
        case seeked
        case rebufferStart
        case rebufferEnd
        case variantChanged
        case ended
        case error
        /// Emitted when the SDK warms an item that is not yet on screen.
        case preloadStart
        case preloadReady
        /// A pooled `AVPlayer` was recycled onto a different item.
        case playerRecycled
        case transfer, prefetchError, transportError, startupSummary, runEnd
    }

    public let id = UUID()
    public let kind: Kind
    public let itemID: String
    public let monotonicTime: TimeInterval
    public let timestamp: Date
    /// Player position when the event fired, seconds.
    public let position: TimeInterval
    /// Numeric payload (durations in ms, bitrates in bps, counts).
    public let metrics: [String: Double]
    /// String payload (variant URL, error message, custom dimensions).
    public let properties: [String: String]

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
