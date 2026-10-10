import Foundation

/// Partner engagement sessions. Hooks run synchronously on the main actor for current and next only.
///
/// Access on the main actor.
@MainActor public protocol HMInteractionSource: AnyObject {
    /// Returns a clock-indexed timeline; constructing one must not open a network session.
    ///
    /// Access on the main actor.
    func timeline(for item: HMMediaItem) -> HMStreamTimeline
    /// Opens or prepares the next entry's session.
    ///
    /// Access on the main actor.
    func willBecomeNext(_ item: HMMediaItem)
    /// Promotes the current entry's session.
    ///
    /// Access on the main actor.
    func didBecomeCurrent(_ item: HMMediaItem)
    /// Closes a session that left the current-plus-next window.
    ///
    /// Access on the main actor.
    func didLeave(_ item: HMMediaItem)
    /// Optional action; unsupported implementations throw `HMInteractionError.unsupportedAction`.
    ///
    /// Access on the main actor.
    func sendChat(_ text: String, for item: HMMediaItem) async throws
    /// Sends the viewer's message and returns the confirmed server event (ID, author, wall time,
    /// counts), which replaces the local message; nil keeps the local ID (`message.id`).
    /// Defaults to calling `sendChat(message.text, for:)` and returning nil.
    ///
    /// Access on the main actor.
    func sendChat(_ message: HMChatMessage, for item: HMMediaItem) async throws -> HMTimelineEvent?
    /// Optional reaction action.
    ///
    /// Access on the main actor.
    func react(_ emoji: String, for item: HMMediaItem) async throws
    /// Sends the viewer's stream reaction and returns the confirmed server event, whose ID replaces
    /// the local one (`reaction.id`) so an echo by that ID isn't counted twice; nil keeps the local ID.
    /// Defaults to calling `react(reaction.emoji, for:)` and returning nil.
    ///
    /// Access on the main actor.
    func react(_ reaction: HMTimelineEvent, for item: HMMediaItem) async throws -> HMTimelineEvent?
    /// Sets membership in an item's reaction count. Implement as an idempotent set operation,
    /// returning authoritative totals including the viewer. Separate from timed stream reactions.
    /// Defaults to unsupported; advertise `.toggleReaction` only when implemented.
    func setReaction(_ emoji: String, isReacted: Bool, for item: HMMediaItem) async throws -> HMItemReactionSummary
    /// Loads newest comments for nil, or older comments using the opaque cursor. Item comments
    /// are independent of VOD replay; do not put untimed history on the media timeline.
    /// Defaults to unsupported; advertise `.loadComments` only when implemented.
    func comments(for item: HMMediaItem, before cursor: String?) async throws -> HMCommentPage
    /// Optional poll action.
    ///
    /// Access on the main actor.
    func vote(pollID: String, optionID: String, for item: HMMediaItem) async throws
    /// Actions this source supports for an item; the UI hides controls for the rest. Defaults to read-only.
    ///
    /// Access on the main actor.
    func capabilities(for item: HMMediaItem) -> HMEngagementCapabilities
    /// Polls for an item, on its media clock. Called once when its engagement state is created. Defaults to none.
    ///
    /// Access on the main actor.
    func polls(for item: HMMediaItem) -> [HMPoll]
    /// Optional reaction to one chat message.
    ///
    /// Access on the main actor.
    func react(_ emoji: String, toMessage messageID: String, for item: HMMediaItem) async throws
    /// Called once when an item's engagement state is created. Keep it weakly to push live updates
    /// (`receive(_:)`, `upsertPoll(_:)`, `updateReactions(_:forMessage:)`). Defaults to doing nothing.
    ///
    /// Access on the main actor.
    func engagementDidLoad(_ engagement: HMEngagement)
}
/// An interaction source does not implement the requested action.
///
/// Use from any task; mutate only an exclusively owned value.
public enum HMInteractionError: Error, Sendable, LocalizedError {
    /// The action is unavailable.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case unsupportedAction

    /// Human-readable description.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public var errorDescription: String? { "This action isn't available." }
}
public extension HMInteractionSource {
    /// Default lifecycle hook does nothing.
    ///
    /// Access on the main actor.
    func willBecomeNext(_ item: HMMediaItem) {}
    /// Default lifecycle hook does nothing.
    ///
    /// Access on the main actor.
    func didBecomeCurrent(_ item: HMMediaItem) {}
    /// Default lifecycle hook does nothing.
    ///
    /// Access on the main actor.
    func didLeave(_ item: HMMediaItem) {}
    /// Default sources do not support item reaction membership.
    func setReaction(_ emoji: String, isReacted: Bool, for item: HMMediaItem) async throws -> HMItemReactionSummary {
        throw HMInteractionError.unsupportedAction
    }
    /// Default sources retain media-clock chat without item comment paging.
    func comments(for item: HMMediaItem, before cursor: String?) async throws -> HMCommentPage {
        throw HMInteractionError.unsupportedAction
    }
    /// Default action reports unsupported.
    ///
    /// Access on the main actor.
    func sendChat(_ text: String, for item: HMMediaItem) async throws { throw HMInteractionError.unsupportedAction }
    /// Forwards to the text-only `sendChat(_:for:)`; the local ID is kept.
    ///
    /// Access on the main actor.
    func sendChat(_ message: HMChatMessage, for item: HMMediaItem) async throws -> HMTimelineEvent? {
        try await sendChat(message.text, for: item); return nil
    }
    /// Forwards to the emoji-only `react(_:for:)`; the local ID is kept.
    ///
    /// Access on the main actor.
    func react(_ reaction: HMTimelineEvent, for item: HMMediaItem) async throws -> HMTimelineEvent? {
        try await react(reaction.emoji ?? "", for: item); return nil
    }
    /// Default action reports unsupported.
    ///
    /// Access on the main actor.
    func react(_ emoji: String, for item: HMMediaItem) async throws { throw HMInteractionError.unsupportedAction }
    /// Default action reports unsupported.
    ///
    /// Access on the main actor.
    func vote(pollID: String, optionID: String, for item: HMMediaItem) async throws { throw HMInteractionError.unsupportedAction }
    /// Default sources are display-only, so no action controls appear.
    ///
    /// Access on the main actor.
    func capabilities(for item: HMMediaItem) -> HMEngagementCapabilities { .readOnly }
    /// Default sources have no polls.
    ///
    /// Access on the main actor.
    func polls(for item: HMMediaItem) -> [HMPoll] { [] }
    /// Default action reports unsupported.
    ///
    /// Access on the main actor.
    func react(_ emoji: String, toMessage messageID: String, for item: HMMediaItem) async throws { throw HMInteractionError.unsupportedAction }
    /// Default sources push no updates.
    ///
    /// Access on the main actor.
    func engagementDidLoad(_ engagement: HMEngagement) {}
}
/// The source a player uses when none is supplied: no events, no polls, no actions.
/// Partners never see invented engagement unless they opt into the demo source.
@MainActor final class HMEmptyInteractionSource: HMInteractionSource {
    func timeline(for item: HMMediaItem) -> HMStreamTimeline { HMEmptyTimeline(duration: item.durationHint ?? 0) }
}

/// A timeline with nothing on it. Appends are ignored, as the protocol default allows.
@MainActor final class HMEmptyTimeline: HMStreamTimeline {
    let duration: TimeInterval
    init(duration: TimeInterval) { self.duration = max(0, duration) }
    func events(in range: ClosedRange<TimeInterval>) -> [HMTimelineEvent] { [] }
    var density: [HMDensityBucket] { [] }
    var markers: [HMTimelineMarker] { [] }
}

/// Deterministic demo engagement without network sessions: timelines, polls and
/// every action, accepted after a short simulated round trip. Opt-in Benchmark SPI for
/// demos; pass it as `HMPlayer(interactions:)` explicitly.
@MainActor @_spi(Benchmark) public final class HMMockInteractionSource: HMInteractionSource {
    private var itemReactions: [String: [String: HMItemReactionSummary]] = [:]
    /// Actions the mock accepts; narrow it to preview capability gating.
    public var capabilities: HMEngagementCapabilities
    /// Simulated round trip for every action.
    public var latency: Duration
    /// Creates the default demo provider.
    public init(capabilities: HMEngagementCapabilities = [.all, .toggleReaction, .loadComments], latency: Duration = .milliseconds(180)) {
        self.capabilities = capabilities
        self.latency = latency
    }
    /// Generates a timeline on the media clock.
    public func timeline(for item: HMMediaItem) -> HMStreamTimeline { HMMockTimeline(itemID: item.id, duration: item.durationHint ?? 20) }
    /// Every demo item supports the configured actions.
    public func capabilities(for item: HMMediaItem) -> HMEngagementCapabilities { capabilities }
    /// One deterministic poll per item, open for the middle of the clip.
    public func polls(for item: HMMediaItem) -> [HMPoll] { HMMockTimeline.polls(itemID: item.id, duration: item.durationHint ?? 20) }
    /// Accepts after the simulated latency.
    public func sendChat(_ text: String, for item: HMMediaItem) async throws { try await roundTrip(.sendChat) }
    /// Accepts after the simulated latency and returns a server-style confirmed message.
    public func sendChat(_ message: HMChatMessage, for item: HMMediaItem) async throws -> HMTimelineEvent? {
        try await roundTrip(.sendChat)
        return HMTimelineEvent(id: "srv-msg-\(UUID().uuidString.prefix(12))", offset: message.offset, kind: .chat,
                               author: "You", text: message.text, wallTime: Date())
    }
    /// Accepts after the simulated latency.
    public func react(_ emoji: String, for item: HMMediaItem) async throws { try await roundTrip(.reactToStream) }
    /// Accepts after the simulated latency and returns a server-style confirmed reaction.
    public func react(_ reaction: HMTimelineEvent, for item: HMMediaItem) async throws -> HMTimelineEvent? {
        try await roundTrip(.reactToStream)
        return HMTimelineEvent(id: "srv-rx-\(UUID().uuidString.prefix(12))", offset: reaction.offset, kind: .reaction,
                               emoji: reaction.emoji, wallTime: Date())
    }
    /// Accepts after the simulated latency.
    public func react(_ emoji: String, toMessage messageID: String, for item: HMMediaItem) async throws { try await roundTrip(.reactToMessage) }
    /// Accepts after the simulated latency.
    public func vote(pollID: String, optionID: String, for item: HMMediaItem) async throws { try await roundTrip(.vote) }

    /// Seeds known item metadata for the opt-in demo.
    public func engagementDidLoad(_ engagement: HMEngagement) {
        engagement.updateReactionSummary(itemReactions[engagement.item.id]?["🔥"] ?? .init(count: 0, reactedByViewer: false), for: "🔥")
    }
    /// Sets idempotent membership after simulated latency.
    public func setReaction(_ emoji: String, isReacted: Bool, for item: HMMediaItem) async throws -> HMItemReactionSummary {
        try await roundTrip(.toggleReaction)
        let old = itemReactions[item.id]?[emoji] ?? HMItemReactionSummary(count: 0, reactedByViewer: false)
        let summary = HMItemReactionSummary(count: old.count + (old.reactedByViewer == isReacted ? 0 : (isReacted ? 1 : -1)), reactedByViewer: isReacted)
        itemReactions[item.id, default: [:]][emoji] = summary
        return summary
    }
    /// Provides one independent item-comment page for the opt-in demo.
    public func comments(for item: HMMediaItem, before cursor: String?) async throws -> HMCommentPage {
        try await roundTrip(.loadComments)
        return HMCommentPage(comments: [], totalCount: 0)
    }

    private func roundTrip(_ capability: HMEngagementCapabilities) async throws {
        guard capabilities.isSuperset(of: capability) else { throw HMInteractionError.unsupportedAction }
        try await Task.sleep(for: latency)
    }
}
