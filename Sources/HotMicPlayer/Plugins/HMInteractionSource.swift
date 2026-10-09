import Foundation

/// Partner engagement sessions. Hooks run synchronously on the main actor for current and next only.
@MainActor public protocol HMInteractionSource: AnyObject {
    /// Returns a clock-indexed timeline; constructing one must not open a network session.
    func timeline(for item: HMMediaItem) -> HMStreamTimeline
    /// Opens or prepares the next entry's session.
    func willBecomeNext(_ item: HMMediaItem)
    /// Promotes the current entry's session.
    func didBecomeCurrent(_ item: HMMediaItem)
    /// Closes a session that left the current-plus-next window.
    func didLeave(_ item: HMMediaItem)
    /// Optional action; unsupported implementations throw `HMInteractionError.unsupportedAction`.
    func sendChat(_ text: String, for item: HMMediaItem) async throws
    /// Sends the viewer's message with its client ID. Implement this instead of `sendChat(_:for:)`
    /// to echo the message back through `HMEngagement.receive(_:)` with the same ID, which the
    /// engagement de-duplicates. Defaults to `sendChat(message.text, for:)`.
    func sendChat(_ message: HMChatMessage, for item: HMMediaItem) async throws
    /// Optional reaction action.
    func react(_ emoji: String, for item: HMMediaItem) async throws
    /// Optional poll action.
    func vote(pollID: String, optionID: String, for item: HMMediaItem) async throws
    /// Actions this source supports for an item; the UI hides controls for the rest. Defaults to read-only.
    func capabilities(for item: HMMediaItem) -> HMEngagementCapabilities
    /// Polls for an item, on its media clock. Called once when its engagement state is created. Defaults to none.
    func polls(for item: HMMediaItem) -> [HMPoll]
    /// Optional reaction to one chat message.
    func react(_ emoji: String, toMessage messageID: String, for item: HMMediaItem) async throws
    /// Called once when an item's engagement state is created. Keep it weakly to push live updates
    /// (`receive(_:)`, `update(_:)`, `updateReactions(_:forMessage:)`). Defaults to doing nothing.
    func engagementDidLoad(_ engagement: HMEngagement)
}
/// An interaction source does not implement the requested action.
public enum HMInteractionError: Error, Sendable, LocalizedError {
    /// The action is unavailable.
    case unsupportedAction

    /// Human-readable description.
    public var errorDescription: String? { "This action isn't available." }
}
public extension HMInteractionSource {
    /// Default lifecycle hook does nothing.
    func willBecomeNext(_ item: HMMediaItem) {}
    /// Default lifecycle hook does nothing.
    func didBecomeCurrent(_ item: HMMediaItem) {}
    /// Default lifecycle hook does nothing.
    func didLeave(_ item: HMMediaItem) {}
    /// Default action reports unsupported.
    func sendChat(_ text: String, for item: HMMediaItem) async throws { throw HMInteractionError.unsupportedAction }
    /// Forwards to the text-only `sendChat(_:for:)`.
    func sendChat(_ message: HMChatMessage, for item: HMMediaItem) async throws { try await sendChat(message.text, for: item) }
    /// Default action reports unsupported.
    func react(_ emoji: String, for item: HMMediaItem) async throws { throw HMInteractionError.unsupportedAction }
    /// Default action reports unsupported.
    func vote(pollID: String, optionID: String, for item: HMMediaItem) async throws { throw HMInteractionError.unsupportedAction }
    /// Default sources are display-only, so no action controls appear.
    func capabilities(for item: HMMediaItem) -> HMEngagementCapabilities { .readOnly }
    /// Default sources have no polls.
    func polls(for item: HMMediaItem) -> [HMPoll] { [] }
    /// Default action reports unsupported.
    func react(_ emoji: String, toMessage messageID: String, for item: HMMediaItem) async throws { throw HMInteractionError.unsupportedAction }
    /// Default sources push no updates.
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
    /// Actions the mock accepts; narrow it to preview capability gating.
    public var capabilities: HMEngagementCapabilities
    /// Simulated round trip for every action.
    public var latency: Duration
    /// Creates the default demo provider.
    public init(capabilities: HMEngagementCapabilities = .all, latency: Duration = .milliseconds(180)) {
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
    /// Accepts after the simulated latency.
    public func react(_ emoji: String, for item: HMMediaItem) async throws { try await roundTrip(.reactToStream) }
    /// Accepts after the simulated latency.
    public func react(_ emoji: String, toMessage messageID: String, for item: HMMediaItem) async throws { try await roundTrip(.reactToMessage) }
    /// Accepts after the simulated latency.
    public func vote(pollID: String, optionID: String, for item: HMMediaItem) async throws { try await roundTrip(.vote) }

    private func roundTrip(_ capability: HMEngagementCapabilities) async throws {
        guard capabilities.isSuperset(of: capability) else { throw HMInteractionError.unsupportedAction }
        try await Task.sleep(for: latency)
    }
}
