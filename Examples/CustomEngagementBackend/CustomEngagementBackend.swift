import Foundation
import HotMicPlayer

/// Copy this adapter into a host app and replace FakeRESTClient with the app's REST client.
/// It deliberately owns no timer, player, or UI. HMEngagement owns optimism and rollback.
@MainActor final class CustomEngagementBackend: HMInteractionSource {
    let client: FakeRESTClient
    private var engagements: [String: WeakEngagement] = [:]
    init(client: FakeRESTClient? = nil) { self.client = client ?? FakeRESTClient() }
    func timeline(for item: HMMediaItem) -> HMStreamTimeline { EmptyCommentTimeline(duration: item.durationHint ?? 0) }
    func capabilities(for item: HMMediaItem) -> HMEngagementCapabilities { [.sendChat, .toggleReaction, .loadComments] }
    func engagementDidLoad(_ engagement: HMEngagement) {
        engagements[engagement.item.id] = WeakEngagement(engagement)
        // The fake has cached metadata. Real clients should fetch asynchronously in lifecycle hooks,
        // then publish on the main actor. Timeline creation must never open a network session.
        engagement.updateReactionSummary(client.fire(for: engagement.item.id), for: "🔥")
        engagement.updateCommentCount(client.count(for: engagement.item.id))
    }
    func didLeave(_ item: HMMediaItem) { engagements[item.id] = nil }
    func comments(for item: HMMediaItem, before cursor: String?) async throws -> HMCommentPage {
        try await client.getComments(itemID: item.id, before: cursor)
    }
    func setReaction(_ emoji: String, isReacted: Bool, for item: HMMediaItem) async throws -> HMItemReactionSummary {
        guard emoji == "🔥" else { throw HMInteractionError.unsupportedAction }
        return try await client.putFire(itemID: item.id, reacted: isReacted)
    }
    func sendChat(_ message: HMChatMessage, for item: HMMediaItem) async throws -> HMTimelineEvent? {
        let event = try await client.postComment(itemID: item.id, text: message.text, offset: message.offset)
        engagements[item.id]?.value?.updateCommentCount(client.count(for: item.id))
        return event
    }
    private final class WeakEngagement {
        weak var value: HMEngagement?
        init(_ value: HMEngagement) { self.value = value }
    }
}

/// REST-shaped, in-memory server. State is isolated per item; a failed mutation commits nothing.
@MainActor final class FakeRESTClient {
    var failNextRequest = false
    var latency: Duration = .milliseconds(350)
    private var fires: [String: HMItemReactionSummary] = [:]
    private var history: [String: [HMTimelineEvent]] = [:]
    func fire(for itemID: String) -> HMItemReactionSummary {
        fires[itemID] ?? HMItemReactionSummary(count: 12_345, reactedByViewer: false)
    }
    func count(for itemID: String) -> Int { seed(itemID).count }
    // GET /items/:id/comments?before=:cursor. Three newest rows first, opaque older cursor.
    func getComments(itemID: String, before cursor: String?) async throws -> HMCommentPage {
        try await request()
        let all = seed(itemID)
        let end: Int
        if let cursor {
            guard let index = all.firstIndex(where: { $0.id == cursor }) else { throw URLError(.badURL) }
            end = index
        } else { end = all.count }
        let start = max(0, end - 3)
        return HMCommentPage(comments: Array(all[start..<end]), olderCursor: start > 0 ? all[start].id : nil, totalCount: all.count)
    }
    // PUT /items/:id/reactions/fire { reacted: Bool }. Idempotent membership, never an increment.
    func putFire(itemID: String, reacted: Bool) async throws -> HMItemReactionSummary {
        try await request()
        let old = fire(for: itemID)
        let next = HMItemReactionSummary(count: old.count + (old.reactedByViewer == reacted ? 0 : (reacted ? 1 : -1)), reactedByViewer: reacted)
        fires[itemID] = next
        return next
    }
    // POST /items/:id/comments. Server supplies ID, author and timestamp.
    func postComment(itemID: String, text: String, offset: TimeInterval) async throws -> HMTimelineEvent {
        try await request()
        let event = HMTimelineEvent(id: UUID().uuidString, offset: offset, kind: .chat, author: "You", text: text, wallTime: Date())
        history[itemID] = seed(itemID) + [event]
        return event
    }
    private func request() async throws {
        let fails = failNextRequest; failNextRequest = false
        try await Task.sleep(for: latency)
        if fails { throw URLError(.cannotConnectToHost) }
    }
    private func seed(_ id: String) -> [HMTimelineEvent] {
        if let comments = history[id] { return comments }
        let texts = ["What a start!", "Run that back.", "Great teamwork.", "That finish!", "What a play!", "Watching again."]
        let comments = texts.enumerated().map { index, text in
            HMTimelineEvent(id: "\(id)-comment-\(index)", offset: 0, kind: .chat,
                author: index.isMultiple(of: 2) ? "courtside" : "fan", text: text, wallTime: Date(timeIntervalSince1970: Double(index)))
        }
        history[id] = comments
        return comments
    }
}

@MainActor private final class EmptyCommentTimeline: HMStreamTimeline {
    let duration: TimeInterval
    init(duration: TimeInterval) { self.duration = duration }
    func events(in range: ClosedRange<TimeInterval>) -> [HMTimelineEvent] { [] }
    var density: [HMDensityBucket] { [] }
    var markers: [HMTimelineMarker] { [] }
}
