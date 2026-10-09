import Foundation

/// Actions an interaction source supports for an item.
///
/// Display needs no capability: whatever the timeline and polls contain is shown.
/// Capabilities only gate *actions*, and the UI components hide the matching
/// control when one is missing rather than offering a button that throws.
public struct HMEngagementCapabilities: OptionSet, Sendable, Hashable {
    /// Raw option bits.
    public let rawValue: Int
    /// Creates a capability set from raw bits.
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The viewer can send chat messages.
    public static let sendChat = HMEngagementCapabilities(rawValue: 1 << 0)
    /// The viewer can react to the stream itself (floating reactions, the waveform).
    public static let reactToStream = HMEngagementCapabilities(rawValue: 1 << 1)
    /// The viewer can react to an individual chat message.
    public static let reactToMessage = HMEngagementCapabilities(rawValue: 1 << 2)
    /// The viewer can vote in polls.
    public static let vote = HMEngagementCapabilities(rawValue: 1 << 3)

    /// Every action.
    public static let all: HMEngagementCapabilities = [.sendChat, .reactToStream, .reactToMessage, .vote]
    /// Display only; every action control is hidden.
    public static let readOnly: HMEngagementCapabilities = []
}

/// A chat message positioned on the item's media clock.
public struct HMChatMessage: Identifiable, Sendable, Equatable {
    /// Delivery state of a message the viewer sent.
    public enum Delivery: Sendable, Equatable {
        /// Delivered, or not the viewer's message.
        case sent
        /// Sent by the viewer and awaiting the source's confirmation.
        case sending
    }

    /// Stable identity, shared with the underlying timeline event.
    public let id: String
    /// Author display name.
    public let author: String
    /// Author avatar, if the source has one. Components fall back to a monogram.
    public let avatarURL: URL?
    /// Message text.
    public let text: String
    /// Seconds from the start of the item.
    public let offset: TimeInterval
    /// Wall-clock time the message was originally sent, if known.
    public let wallTime: Date?
    /// Reaction counts keyed by emoji, including the viewer's own reactions.
    public var reactions: [String: Int]
    /// Emoji the viewer has reacted with on this message.
    public var ownReactions: Set<String>
    /// Whether the viewer sent this message.
    public let isOwn: Bool
    /// Delivery state; always `.sent` for other viewers' messages.
    public var delivery: Delivery

    /// Creates a chat message.
    public init(id: String, author: String, avatarURL: URL? = nil, text: String, offset: TimeInterval,
                wallTime: Date? = nil, reactions: [String: Int] = [:], ownReactions: Set<String> = [],
                isOwn: Bool = false, delivery: Delivery = .sent) {
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
    }

    /// Total reactions across every emoji.
    public var reactionCount: Int { reactions.values.reduce(0, +) }
}

/// A poll that is open for a window of the item's media clock.
public struct HMPoll: Identifiable, Sendable, Equatable {
    /// One answer.
    public struct Option: Identifiable, Sendable, Equatable {
        /// Stable option identity, sent back with a vote.
        public let id: String
        /// Answer text.
        public let text: String
        /// Votes for this answer, including the viewer's.
        public var votes: Int

        /// Creates a poll option.
        public init(id: String, text: String, votes: Int = 0) {
            self.id = id
            self.text = text
            self.votes = votes
        }
    }

    /// Stable poll identity.
    public let id: String
    /// The question.
    public let question: String
    /// Answers in display order.
    public var options: [Option]
    /// The option the viewer voted for, if any.
    public var viewerVote: String?
    /// Media time at which the poll opens.
    public let opensAt: TimeInterval
    /// Media time at which voting closes; nil keeps it open to the end of the item.
    public let closesAt: TimeInterval?
    /// Closed by the source regardless of the window, for example ended early by a producer.
    public var isClosed: Bool

    /// Creates a poll.
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
    public var totalVotes: Int { options.reduce(0) { $0 + $1.votes } }

    /// Whether voting is possible at a media time.
    public func isOpen(at offset: TimeInterval) -> Bool {
        !isClosed && offset >= opensAt && closesAt.map { offset < $0 } ?? true
    }

    /// Whether the poll should be on screen at a media time: while open, then
    /// for `resultsLinger` seconds after it closes so the result can be read.
    public func isVisible(at offset: TimeInterval, resultsLinger: TimeInterval) -> Bool {
        guard offset >= opensAt else { return false }
        guard let closesAt else { return true }
        return offset < closesAt + max(0, resultsLinger)
    }

    /// Share of votes for an option, from zero to one.
    public func share(of optionID: String) -> Double {
        let total = totalVotes
        guard total > 0, let option = options.first(where: { $0.id == optionID }) else { return 0 }
        return Double(option.votes) / Double(total)
    }
}

/// The viewer's own stream reaction, published so overlays can animate it at once.
public struct HMReactionEcho: Sendable, Equatable {
    /// Increments with every reaction, so repeated taps on one emoji are distinct.
    public let id: Int
    /// The emoji sent.
    public let emoji: String

    /// Creates an echo.
    public init(id: Int, emoji: String) {
        self.id = id
        self.emoji = emoji
    }
}

/// Validation failures for engagement actions. Unsupported actions throw `HMInteractionError.unsupportedAction`.
public enum HMEngagementError: Error, Sendable, Equatable, LocalizedError {
    /// Chat text was empty after trimming whitespace.
    case emptyMessage
    /// Chat text exceeded `HMEngagement.maximumMessageLength`.
    case messageTooLong
    /// The poll does not exist.
    case unknownPoll
    /// The poll is not open at the current media time.
    case pollClosed
    /// The viewer already voted in this poll.
    case alreadyVoted
    /// The chat message does not exist.
    case unknownMessage

    /// Human-readable description, suitable for an inline error.
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
