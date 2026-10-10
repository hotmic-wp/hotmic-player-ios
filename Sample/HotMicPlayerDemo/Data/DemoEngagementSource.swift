import Foundation
import HotMicPlayer

/// Offline stand-in for a Connect client. No HotMicCore dependency or network calls.
/// The real HotMicInteractionSource is supplied by the separate Connect package.
@MainActor final class FakeConnectClient {
    let backend = FakeRESTClient()
    func comments(_ item: HMMediaItem, cursor: String?) async throws -> HMCommentPage {
        try await backend.getComments(itemID: item.id, before: cursor)
    }
    func setFire(_ item: HMMediaItem, reacted: Bool) async throws -> HMItemReactionSummary {
        try await backend.putFire(itemID: item.id, reacted: reacted)
    }
    func post(_ message: HMChatMessage, item: HMMediaItem) async throws -> HMTimelineEvent {
        try await backend.postComment(itemID: item.id, text: message.text, offset: message.offset)
    }
}

@MainActor final class DemoConnectInteractionSource: HMInteractionSource {
    let client = FakeConnectClient()
    func timeline(for item: HMMediaItem) -> HMStreamTimeline { DemoConnectTimeline(duration: item.durationHint ?? 12) }
    func capabilities(for item: HMMediaItem) -> HMEngagementCapabilities { [.sendChat, .toggleReaction, .loadComments] }
    func engagementDidLoad(_ engagement: HMEngagement) {
        engagement.updateReactionSummary(client.backend.fire(for: engagement.item.id), for: "🔥")
        engagement.updateCommentCount(client.backend.count(for: engagement.item.id))
    }
    func comments(for item: HMMediaItem, before cursor: String?) async throws -> HMCommentPage {
        try await client.comments(item, cursor: cursor)
    }
    func setReaction(_ emoji: String, isReacted: Bool, for item: HMMediaItem) async throws -> HMItemReactionSummary {
        guard emoji == "🔥" else { throw HMInteractionError.unsupportedAction }
        return try await client.setFire(item, reacted: isReacted)
    }
    func sendChat(_ message: HMChatMessage, for item: HMMediaItem) async throws -> HMTimelineEvent? {
        try await client.post(message, item: item)
    }
}

/// Timed replay remains available alongside independent item comments.
@MainActor private final class DemoConnectTimeline: HMStreamTimeline {
    let duration: TimeInterval
    init(duration: TimeInterval) { self.duration = duration }
    func events(in range: ClosedRange<TimeInterval>) -> [HMTimelineEvent] {
        [HMTimelineEvent(id: "replay-1", offset: 2, kind: .chat, author: "fan", text: "Replay at two seconds")].filter { range.contains($0.offset) }
    }
    var density: [HMDensityBucket] { [] }
    var markers: [HMTimelineMarker] { [] }
}
