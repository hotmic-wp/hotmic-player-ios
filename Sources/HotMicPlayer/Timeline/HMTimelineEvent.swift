import Foundation

/// A HotMic engagement event, positioned on the stream's own clock.
///
/// Everything an overlay renders — chat, reactions, votes, polls — is one of
/// these. Overlays never ask "is this live?"; they ask the timeline for a window
/// and draw what comes back. Live, DVR and VOD then share one code path.
public struct HMTimelineEvent: Identifiable, Sendable, Equatable {

    /// Supported clock-indexed engagement categories.
    public enum Kind: String, Sendable, CaseIterable {
        /// A chat message.
        case chat
        /// An emoji reaction.
        case reaction
        /// A vote event.
        case vote
        /// A poll event.
        case poll
        /// A question event.
        case question
        /// A tip event.
        case tip
        /// An authored highlight (winner reveal, round change, sponsor beat).
        case marker
    }

    /// Stable identity for this value.
    public let id: String
    /// Seconds from the start of the stream.
    public let offset: TimeInterval
    /// Event category.
    public let kind: Kind
    /// Optional author display name.
    public let author: String?
    /// Optional event text.
    public let text: String?
    /// Emoji for reactions/votes; also what the scrubber rail renders.
    public let emoji: String?
    /// Engagement weight used in density aggregation.
    public let magnitude: Int
    /// Author avatar for chat events, if the source has one.
    public let avatarURL: URL?
    /// Wall-clock time the event was originally sent, if known. Display only; ordering uses `offset`.
    public let wallTime: Date?
    /// Reaction counts on this event (chat messages), keyed by emoji, as of when the source built it.
    public let reactions: [String: Int]

    /// Creates a media-clock event or precomputed engagement aggregate.
    public init(
        id: String = UUID().uuidString,
        offset: TimeInterval,
        kind: Kind,
        author: String? = nil,
        text: String? = nil,
        emoji: String? = nil,
        magnitude: Int = 1,
        avatarURL: URL? = nil,
        wallTime: Date? = nil,
        reactions: [String: Int] = [:]
    ) {
        self.id = id
        self.offset = offset
        self.kind = kind
        self.author = author
        self.text = text
        self.emoji = emoji
        self.magnitude = magnitude
        self.avatarURL = avatarURL
        self.wallTime = wallTime
        self.reactions = reactions
    }
}

/// Pre-aggregated engagement volume for the scrubber's density ribbon.
///
/// Deliberately precomputed: the rail must never scan the raw event list on a
/// time tick. Today it is built once when the mock timeline is generated; in
/// production this is what a `GET /streams/:id/timeline` endpoint would return.
public struct HMDensityBucket: Sendable, Equatable, Identifiable {
    /// Stable identity for this value.
    public var id: Int { index }
    /// Zero-based density bucket index.
    public let index: Int
    /// Normalised 0...1 position along the stream.
    public let position: Double
    /// Normalised 0...1 engagement volume, relative to the busiest bucket.
    public let intensity: Double
    /// Emoji that dominated this bucket, if any.
    public let dominantEmoji: String?
    /// Number of events folded into this bucket.
    public let eventCount: Int

    /// Creates a media-clock event or precomputed engagement aggregate.
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
    /// Stable identity for this value.
    public let id: String
    /// Event time from the start of the VOD, in seconds.
    public let offset: TimeInterval
    /// Normalised media-clock position, from zero to one.
    public let position: Double
    /// Emoji displayed at this timeline peak.
    public let emoji: String
    /// Number of events clustered into the peak.
    public let count: Int
    /// Optional text describing the peak.
    public let label: String?

    /// Creates a media-clock event or precomputed engagement aggregate.
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
    /// Duration of the timeline on the VOD clock, in seconds.
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
    /// Default immutable timelines ignore appended events.
    func append(_ event: HMTimelineEvent) {}
}
