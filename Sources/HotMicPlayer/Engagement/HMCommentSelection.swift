import Foundation

/// A comment that an `HMCommentSelection` can rank. `HMChatMessage` and the kit's `HMSocialComment`
/// conform. Rules added later introduce requirements with default implementations, so a host type
/// that conforms today keeps compiling.
///
/// Use from any task; mutate only an exclusively owned value.
public protocol HMSelectableComment {
    /// Stable comment identity, matched against a pinned comment by rules that use one.
    var id: String { get }
}

extension HMChatMessage: HMSelectableComment {}

/// Which comments a preview shows, and how many: a named rule plus a limit.
///
/// The value is plain data with a stable wire form (`{"rule":"recent","limit":2}` as JSON, or the
/// `rule` and `limit` query items), so a backend endpoint and an Android client accept the same
/// vocabulary, and a list the server chose under a rule is interchangeable with a list the client
/// chose under that rule. Applying it is a pure function over an oldest-first list: it never reads
/// a clock, and it returns a subsequence in the input order, so a preview rotates through the same
/// comments in the same order everywhere.
///
/// `recent` is the only rule today. The wire names `topReactions` (`window` seconds back from the
/// newest comment's wall time and a `minimum` reaction count), `verifiedOnly` and `pinnedFirst` are
/// reserved. A rule this SDK does not know keeps its name on the wire and previews as `recent`, so a
/// newer server never breaks an older client.
///
/// Use from any task; mutate only an exclusively owned value.
public struct HMCommentSelection: Hashable, Codable, Sendable {
    /// The most comments any selection returns. Larger limits are clamped when applied.
    public static let maximumLimit = 3
    /// The two newest comments by list order: the default preview rule.
    public static let recent = HMCommentSelection(rule: "recent", limit: 2)
    /// The newest `limit` comments by list order, clamped to `1...maximumLimit` when applied.
    public static func recent(limit: Int) -> HMCommentSelection { HMCommentSelection(rule: "recent", limit: limit) }
    /// The rule's wire name, for example `"recent"`. Unknown names are kept and applied as `recent`.
    public let rule: String
    /// How many comments were asked for. Clamped to `1...maximumLimit` when applied.
    public let limit: Int
    private init(rule: String, limit: Int) { self.rule = rule; self.limit = limit }
    /// The `rule` and `limit` query items, for a request to a preview-comments endpoint.
    public var queryItems: [URLQueryItem] {
        [URLQueryItem(name: "rule", value: rule), URLQueryItem(name: "limit", value: String(limit))]
    }
    /// Reads the `rule` and `limit` query items. A missing rule means `recent`; a missing or malformed limit means two.
    public init(queryItems: [URLQueryItem]) {
        let name = queryItems.last { $0.name == "rule" }?.value ?? ""
        let requested = queryItems.last { $0.name == "limit" }?.value.flatMap { Int($0) }
        self.init(rule: name.isEmpty ? "recent" : name, limit: requested ?? 2)
    }
    /// Applies the rule to comments ordered oldest first and returns at most `limit` of them in the same
    /// order: at least one when the list is not empty, `maximumLimit` at most. Pure; it reads no clock.
    public func apply<Comment: HMSelectableComment>(to comments: [Comment]) -> [Comment] {
        let count = min(Self.maximumLimit, max(1, limit))
        // `recent`, and the fallback for rules this SDK does not know: the newest by list order.
        return Array(comments.suffix(count))
    }
}
