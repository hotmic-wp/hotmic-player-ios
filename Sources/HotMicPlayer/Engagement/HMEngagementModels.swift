import Foundation

/// Actions an interaction source supports for an item.
///
/// Display needs no capability: whatever the timeline and polls contain is shown.
/// Capabilities only gate *actions*, and the UI components hide the matching
/// control when one is missing rather than offering a button that throws.
///
/// Use from any task; mutate only an exclusively owned value.
public struct HMEngagementCapabilities: OptionSet, Sendable, Hashable {
    /// Raw option bits.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let rawValue: Int
    /// Creates a capability set from raw bits.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The viewer can send chat messages.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public static let sendChat = HMEngagementCapabilities(rawValue: 1 << 0)
    /// The viewer can react to the stream itself (floating reactions, the waveform).
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public static let reactToStream = HMEngagementCapabilities(rawValue: 1 << 1)
    /// The viewer can react to an individual chat message.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public static let reactToMessage = HMEngagementCapabilities(rawValue: 1 << 2)
    /// The viewer can vote in polls.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public static let vote = HMEngagementCapabilities(rawValue: 1 << 3)

    /// The viewer can toggle membership in an item's reaction count.
    public static let toggleReaction = HMEngagementCapabilities(rawValue: 1 << 4)
    /// The source can load item comments independently of the media clock.
    public static let loadComments = HMEngagementCapabilities(rawValue: 1 << 5)

    /// Every action.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public static let all: HMEngagementCapabilities = [.sendChat, .reactToStream, .reactToMessage, .vote, .toggleReaction, .loadComments]
    /// Display only; every action control is hidden.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public static let readOnly: HMEngagementCapabilities = []
}

/// A chat message positioned on the item's media clock.
///
/// Use from any task; mutate only an exclusively owned value.
public struct HMChatMessage: Identifiable, Sendable, Equatable {
    /// Delivery state of a message the viewer sent.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public enum Delivery: Sendable, Equatable {
        /// Delivered, or not the viewer's message.
        ///
        /// Use from any task; mutate only an exclusively owned value.
        case sent
        /// Sent by the viewer and awaiting the source's confirmation.
        ///
        /// Use from any task; mutate only an exclusively owned value.
        case sending
    }

    /// Stable identity, shared with the underlying timeline event.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let id: String
    /// Author display name.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let author: String
    /// Author avatar, if the source has one. Components fall back to a monogram.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let avatarURL: URL?
    /// Message text.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let text: String
    /// Seconds from the start of the item.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let offset: TimeInterval
    /// Wall-clock time the message was originally sent, if known.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let wallTime: Date?
    /// Reaction counts keyed by emoji, including the viewer's own reactions.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public var reactions: [String: Int]
    /// Emoji the viewer has reacted with on this message.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public var ownReactions: Set<String>
    /// Whether the viewer sent this message.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let isOwn: Bool
    /// Delivery state; always `.sent` for other viewers' messages.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public var delivery: Delivery
    /// For the viewer's own messages, the local ID it was shown under while sending. It stays the
    /// same when the confirmed server message replaces it, so use `rowID` for view identity.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let clientID: String?

    /// Creates a chat message.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public init(id: String, author: String, avatarURL: URL? = nil, text: String, offset: TimeInterval,
                wallTime: Date? = nil, reactions: [String: Int] = [:], ownReactions: Set<String> = [],
                isOwn: Bool = false, delivery: Delivery = .sent, clientID: String? = nil) {
        self.id = id
        self.author = author
        self.avatarURL = avatarURL
        self.text = text
        self.offset = offset
        self.wallTime = wallTime
        self.reactions = reactions
        self.ownReactions = ownReactions
        self.isOwn = isOwn
        self.delivery = delivery
        self.clientID = clientID
    }

    /// Stable identity for a list row: the client ID while one exists, so a sent message
    /// doesn't re-animate when its server ID arrives.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public var rowID: String { clientID ?? id }

    /// Total reactions across every emoji.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public var reactionCount: Int { reactions.values.reduce(0, +) }
}

/// A poll that is open for a window of the item's media clock.
///
/// Use from any task; mutate only an exclusively owned value.
public struct HMPoll: Identifiable, Sendable, Equatable {
    /// One answer.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public struct Option: Identifiable, Sendable, Equatable {
        /// Stable option identity, sent back with a vote.
        ///
        /// Use from any task; mutate only an exclusively owned value.
        public let id: String
        /// Answer text.
        ///
        /// Use from any task; mutate only an exclusively owned value.
        public let text: String
        /// Votes for this answer, including the viewer's.
        ///
        /// Use from any task; mutate only an exclusively owned value.
        public var votes: Int

        /// Creates a poll option.
        ///
        /// Use from any task; mutate only an exclusively owned value.
        public init(id: String, text: String, votes: Int = 0) {
            self.id = id
            self.text = text
            self.votes = votes
        }
    }

    /// Stable poll identity.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let id: String
    /// The question.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let question: String
    /// Answers in display order.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public var options: [Option]
    /// The option the viewer voted for, if any.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public var viewerVote: String?
    /// Media time at which the poll opens.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let opensAt: TimeInterval
    /// Media time at which voting closes; nil keeps it open to the end of the item.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let closesAt: TimeInterval?
    /// Closed by the source regardless of the window, for example ended early by a producer.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public var isClosed: Bool

    /// Creates a poll.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public init(id: String, question: String, options: [Option], viewerVote: String? = nil,
                opensAt: TimeInterval, closesAt: TimeInterval? = nil, isClosed: Bool = false) {
        self.id = id
        self.question = question
        self.options = options
        self.viewerVote = viewerVote
        self.opensAt = opensAt
        self.closesAt = closesAt
        self.isClosed = isClosed
    }

    /// Total votes across options.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public var totalVotes: Int { options.reduce(0) { $0 + $1.votes } }

    /// Whether voting is possible at a media time.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public func isOpen(at offset: TimeInterval) -> Bool {
        !isClosed && offset >= opensAt && closesAt.map { offset < $0 } ?? true
    }

    /// Whether the poll should be on screen at a media time: while open, then
    /// for `resultsLinger` seconds after it closes so the result can be read.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public func isVisible(at offset: TimeInterval, resultsLinger: TimeInterval) -> Bool {
        guard offset >= opensAt else { return false }
        guard let closesAt else { return true }
        return offset < closesAt + max(0, resultsLinger)
    }

    /// Share of votes for an option, from zero to one.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public func share(of optionID: String) -> Double {
        let total = totalVotes
        guard total > 0, let option = options.first(where: { $0.id == optionID }) else { return 0 }
        return Double(option.votes) / Double(total)
    }
}

/// The viewer's own stream reaction, published so overlays can animate it at once.
///
/// Use from any task; mutate only an exclusively owned value.
public struct HMReactionEcho: Sendable, Equatable {
    /// Increments with every reaction, so repeated taps on one emoji are distinct.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let id: Int
    /// The emoji sent.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let emoji: String

    /// Creates an echo.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public init(id: Int, emoji: String) {
        self.id = id
        self.emoji = emoji
    }
}

/// Validation failures for engagement actions. Unsupported actions throw `HMInteractionError.unsupportedAction`.
///
/// Use from any task; mutate only an exclusively owned value.
public enum HMEngagementError: Error, Sendable, Equatable, LocalizedError {
    /// Chat text was empty after trimming whitespace.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case emptyMessage
    /// Chat text exceeded `HMEngagement.maximumMessageLength`.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case messageTooLong
    /// The poll does not exist.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case unknownPoll
    /// The poll is not open at the current media time.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case pollClosed
    /// The viewer already voted in this poll.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case alreadyVoted
    /// The chat message does not exist.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case unknownMessage

    /// Human-readable description, suitable for an inline error.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public var errorDescription: String? {
        switch self {
        case .emptyMessage: "Type a message first."
        case .messageTooLong: "That message is too long."
        case .unknownPoll: "That poll isn't available."
        case .pollClosed: "This poll has closed."
        case .alreadyVoted: "You already voted."
        case .unknownMessage: "That message isn't available."
        }
    }
}

/// An item's reaction count including the viewer, independent of timed reaction volume.
public struct HMItemReactionSummary: Sendable, Equatable {
    /// Total memberships, including the viewer. Negative input is clamped to zero.
    public let count: Int
    /// Whether the signed-in viewer belongs to this count.
    public let reactedByViewer: Bool
    /// Creates authoritative item reaction state.
    public init(count: Int, reactedByViewer: Bool) {
        self.count = max(0, count); self.reactedByViewer = reactedByViewer
    }
}

/// One page of item comments, separate from media-clock replay events.
public struct HMCommentPage: Sendable, Equatable {
    /// Chat events with stable server IDs. Non-chat events are ignored by engagement.
    public let comments: [HMTimelineEvent]
    /// Opaque cursor for older comments; nil means there are no more pages.
    public let olderCursor: String?
    /// Authoritative item comment count, or nil when the backend does not provide it.
    public let totalCount: Int?
    /// Creates a page. Comments may overlap previous pages; IDs are deduplicated.
    public init(comments: [HMTimelineEvent], olderCursor: String? = nil, totalCount: Int? = nil) {
        self.comments = comments; self.olderCursor = olderCursor; self.totalCount = totalCount.map { max(0, $0) }
    }
}
