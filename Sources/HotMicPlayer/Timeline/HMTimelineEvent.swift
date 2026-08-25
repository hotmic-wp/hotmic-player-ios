import Foundation

/// A HotMic engagement event, positioned on the stream's own clock.
///
/// Everything an overlay renders — chat, reactions, votes, polls — is one of
/// these. Overlays never ask "is this live?"; they ask the timeline for a window
/// and draw what comes back. Live, DVR and VOD then share one code path.
public struct HMTimelineEvent: Identifiable, Sendable, Equatable {

    public enum Kind: String, Sendable, CaseIterable {
        case chat
        case reaction
        case vote
        case poll
        case question
        case tip
        /// An authored highlight (winner reveal, round change, sponsor beat).
        case marker
    }

    public let id: String
    /// Seconds from the start of the stream.
    public let offset: TimeInterval
    public let kind: Kind
    public let author: String?
    public let text: String?
    /// Emoji for reactions/votes; also what the scrubber rail renders.
    public let emoji: String?
    public let magnitude: Int

    public init(
        id: String = UUID().uuidString,
        offset: TimeInterval,
        kind: Kind,
        author: String? = nil,
        text: String? = nil,
        emoji: String? = nil,
        magnitude: Int = 1
    ) {
        self.id = id
        self.offset = offset
        self.kind = kind
        self.author = author
        self.text = text
        self.emoji = emoji
        self.magnitude = magnitude
    }
}

/// Pre-aggregated engagement volume for the scrubber's density ribbon.
///
/// Deliberately precomputed: the rail must never scan the raw event list on a
/// time tick. Today it is built once when the mock timeline is generated; in
/// production this is what a `GET /streams/:id/timeline` endpoint would return.
public struct HMDensityBucket: Sendable, Equatable, Identifiable {
    public var id: Int { index }
    public let index: Int
    /// Normalised 0...1 position along the stream.
    public let position: Double
    /// Normalised 0...1 engagement volume, relative to the busiest bucket.
    public let intensity: Double
    /// Emoji that dominated this bucket, if any.
    public let dominantEmoji: String?
    public let eventCount: Int

    public init(index: Int, position: Double, intensity: Double, dominantEmoji: String?, eventCount: Int) {
        self.index = index
        self.position = position
        self.intensity = intensity
        self.dominantEmoji = dominantEmoji
        self.eventCount = eventCount
    }
}

/// A clustered peak worth drawing on the rail as a tappable emoji marker.
public struct HMTimelineMarker: Identifiable, Sendable, Equatable {
    public let id: String
    public let offset: TimeInterval
    public let position: Double
    public let emoji: String
    public let count: Int
    public let label: String?

    public init(id: String, offset: TimeInterval, position: Double, emoji: String, count: Int, label: String? = nil) {
        self.id = id
        self.offset = offset
        self.position = position
        self.emoji = emoji
        self.count = count
        self.label = label
    }
}

/// Source of engagement events for one item.
///
/// The production implementation would wrap `HotMicSDK`'s `StreamSession`
/// callbacks for live and a windowed history fetch for replay. `HMMockTimeline`
/// stands in for both so the feed can be demoed without a backend.
@MainActor
public protocol HMStreamTimeline: AnyObject {
    var duration: TimeInterval { get }
    /// Events whose offset falls inside `range`.
    func events(in range: ClosedRange<TimeInterval>) -> [HMTimelineEvent]
    /// Precomputed density for the scrubber rail.
    var density: [HMDensityBucket] { get }
    /// Clustered peaks, already capped to a drawable number.
    var markers: [HMTimelineMarker] { get }

    /// Add an event and fold it into the aggregates.
    ///
    /// This is the path a viewer's own reaction takes, and in production it is
    /// also how a live socket feeds the timeline. A replay timeline over fixed
    /// history has nothing to add to, so the default does nothing.
    func append(_ event: HMTimelineEvent)
}

public extension HMStreamTimeline {
    func append(_ event: HMTimelineEvent) {}
}
