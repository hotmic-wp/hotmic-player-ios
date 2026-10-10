import Foundation

/// A HotMic engagement event, positioned on the stream's own clock.
///
/// Everything an overlay renders — chat, reactions, votes, polls — is one of
/// these. Overlays never ask "is this live?"; they ask the timeline for a window
/// and draw what comes back. Live, DVR and VOD then share one code path.
///
/// Use from any task; mutate only an exclusively owned value.
public struct HMTimelineEvent: Identifiable, Sendable, Equatable {

    /// Supported clock-indexed engagement categories.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public enum Kind: String, Sendable, CaseIterable {
        /// A chat message.
        ///
        /// Use from any task; mutate only an exclusively owned value.
        case chat
        /// An emoji reaction.
        ///
        /// Use from any task; mutate only an exclusively owned value.
        case reaction
        /// A vote event.
        ///
        /// Use from any task; mutate only an exclusively owned value.
        case vote
        /// A poll event.
        ///
        /// Use from any task; mutate only an exclusively owned value.
        case poll
        /// A question event.
        ///
        /// Use from any task; mutate only an exclusively owned value.
        case question
        /// A tip event.
        ///
        /// Use from any task; mutate only an exclusively owned value.
        case tip
        /// An authored highlight (winner reveal, round change, sponsor beat).
        ///
        /// Use from any task; mutate only an exclusively owned value.
        case marker
    }

    /// Stable identity for this value.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let id: String
    /// Seconds from the start of the stream.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let offset: TimeInterval
    /// Event category.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let kind: Kind
    /// Optional author display name.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let author: String?
    /// Optional event text.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let text: String?
    /// Emoji for reactions/votes; also what the scrubber rail renders.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let emoji: String?
    /// Engagement weight used in density aggregation.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let magnitude: Int
    /// Author avatar for chat events, if the source has one.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let avatarURL: URL?
    /// Wall-clock time the event was originally sent, if known. Display only; ordering uses `offset`.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let wallTime: Date?
    /// Reaction counts on this event (chat messages), keyed by emoji, as of when the source built it.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let reactions: [String: Int]

    /// Creates a media-clock event or precomputed engagement aggregate.
    ///
    /// Use from any task; mutate only an exclusively owned value.
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
///
/// Use from any task; mutate only an exclusively owned value.
public struct HMDensityBucket: Sendable, Equatable, Identifiable {
    /// Stable identity for this value.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public var id: Int { index }
    /// Zero-based density bucket index.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let index: Int
    /// Normalised 0...1 position along the stream.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let position: Double
    /// Normalised 0...1 engagement volume, relative to the busiest bucket.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let intensity: Double
    /// Emoji that dominated this bucket, if any.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let dominantEmoji: String?
    /// Number of events folded into this bucket.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let eventCount: Int

    /// Creates a media-clock event or precomputed engagement aggregate.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public init(index: Int, position: Double, intensity: Double, dominantEmoji: String?, eventCount: Int) {
        self.index = index
        self.position = position
        self.intensity = intensity
        self.dominantEmoji = dominantEmoji
        self.eventCount = eventCount
    }
}

/// A clustered peak worth drawing on the rail as a tappable emoji marker.
///
/// Use from any task; mutate only an exclusively owned value.
public struct HMTimelineMarker: Identifiable, Sendable, Equatable {
    /// Stable identity for this value.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let id: String
    /// Event time from the start of the VOD, in seconds.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let offset: TimeInterval
    /// Normalised media-clock position, from zero to one.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let position: Double
    /// Emoji displayed at this timeline peak.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let emoji: String
    /// Number of events clustered into the peak.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let count: Int
    /// Optional text describing the peak.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let label: String?

    /// Creates a media-clock event or precomputed engagement aggregate.
    ///
    /// Use from any task; mutate only an exclusively owned value.
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
/// Implement this in your interaction source to return media-clock history and
/// precomputed aggregates. The separate HotMicPlayerConnect package supplies the
/// HotMic adapter; custom sources can use their own storage.
///
/// Access on the main actor.
@MainActor
public protocol HMStreamTimeline: AnyObject {
    /// Duration of the timeline on the VOD clock, in seconds.
    ///
    /// Access on the main actor.
    var duration: TimeInterval { get }
    /// Events whose offset falls inside `range`.
    ///
    /// Access on the main actor.
    func events(in range: ClosedRange<TimeInterval>) -> [HMTimelineEvent]
    /// Precomputed density for the scrubber rail.
    ///
    /// Access on the main actor.
    var density: [HMDensityBucket] { get }
    /// Clustered peaks, already capped to a drawable number.
    ///
    /// Access on the main actor.
    var markers: [HMTimelineMarker] { get }

    /// Add an event and fold it into the aggregates.
    ///
    /// This is the path a viewer's own reaction takes, and in production it is
    /// also how a live socket feeds the timeline. A replay timeline over fixed
    /// history has nothing to add to, so the default does nothing.
    ///
    /// Access on the main actor.
    func append(_ event: HMTimelineEvent)
}

public extension HMStreamTimeline {
    /// Default immutable timelines ignore appended events.
    ///
    /// Access on the main actor.
    func append(_ event: HMTimelineEvent) {}
}
