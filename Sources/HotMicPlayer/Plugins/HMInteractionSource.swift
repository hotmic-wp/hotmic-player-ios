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
    /// Optional reaction action.
    func react(_ emoji: String, for item: HMMediaItem) async throws
    /// Optional poll action.
    func vote(pollID: String, optionID: String, for item: HMMediaItem) async throws
}
/// An interaction source does not implement the requested action.
public enum HMInteractionError: Error, Sendable {
    /// The action is unavailable.
    case unsupportedAction
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
    /// Default action reports unsupported.
    func react(_ emoji: String, for item: HMMediaItem) async throws { throw HMInteractionError.unsupportedAction }
    /// Default action reports unsupported.
    func vote(pollID: String, optionID: String, for item: HMMediaItem) async throws { throw HMInteractionError.unsupportedAction }
}
/// Deterministic demo timelines without network sessions.
@MainActor @_spi(Benchmark) public final class HMMockInteractionSource: HMInteractionSource {
    /// Creates the default demo provider.
    public init() {}
    /// Generates a timeline on the media clock.
    public func timeline(for item: HMMediaItem) -> HMStreamTimeline { HMMockTimeline(itemID: item.id, duration: item.durationHint ?? 20) }
}
