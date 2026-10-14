#if DEBUG
import SwiftUI
import Observation
import HotMicPlayer

/// Shared probe state holds the original engagement weakly so it cannot prevent eviction.
@MainActor @Observable final class ModerationDebugSession {
    weak var originalEngagement: HMEngagement?
    var originalItemID: String?
    var removedPoll: HMPoll?
    var removedMessageID: String?
    var removedReactionIDs: Set<String> = []
    var status = "Ready"

    func remember(_ engagement: HMEngagement) {
        if originalItemID == nil {
            originalItemID = engagement.item.id
            originalEngagement = engagement
        }
    }
}

/// Sample-only mock moderation controls, enabled with `--hm-moderation 1`.
struct ModerationDebugView: View {
    let engagement: HMEngagement
    let mediaTime: TimeInterval
    let player: HMPlayer
    let session: ModerationDebugSession

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Mock moderation").font(.caption.bold())
            HStack {
                Button("Delete newest") {
                    if let message = messages.last(where: { !$0.isOwn }) {
                        session.remember(engagement)
                        session.removedMessageID = message.id
                        engagement.removeMessage(id: message.id)
                        session.status = "Deleted newest: \(message.author): \(message.text)"
                    } else { session.status = "No incoming chat" }
                }
                .accessibilityIdentifier("moderation-newest")
                Button("Delete mine") {
                    let time = engagement.duration > 0 ? engagement.duration : mediaTime
                    if let message = engagement.messages(near: time, lookback: time, limit: .max).last(where: \.isOwn) {
                        engagement.removeMessage(id: message.id)
                        session.status = "Deleted mine: \(message.text)"
                    } else { session.status = "No own chat" }
                }
                .accessibilityIdentifier("moderation-own")
            }
            HStack {
                Button("Delete poll") {
                    if let poll = engagement.polls(at: mediaTime).first {
                        session.remember(engagement)
                        session.removedPoll = poll
                        engagement.removePoll(id: poll.id)
                        session.status = "Deleted poll: \(poll.question)"
                    } else { session.status = "No active poll" }
                }
                .accessibilityIdentifier("moderation-poll")
                Button("Delete peak reactions") {
                    guard let marker = engagement.markers.first else { session.status = "No peak"; return }
                    // Clear the events feeding this peak, using the same public stream API.
                    let halfWidth = engagement.duration * 0.08
                    for reaction in engagement.reactions(in: max(0, marker.offset - halfWidth)...(marker.offset + halfWidth)) {
                        session.removedReactionIDs.insert(reaction.id)
                        engagement.removeReaction(id: reaction.id)
                    }
                    session.status = "Deleted peak reactions"
                }
                .accessibilityIdentifier("moderation-peak")
            }
            if DemoOptions().values["moderation-eviction"] == "1" {
                Button("Late poll upsert") {
                    if let poll = session.removedPoll {
                        engagement.upsertPoll(poll)
                        session.status = engagement.polls.contains(where: { $0.id == poll.id }) ? "Poll reappeared" : "Late poll ignored"
                    }
                }
                .accessibilityIdentifier("moderation-late-poll")
                let originalItem = engagement.item.id == session.originalItemID
                let rebuilt = originalItem && session.originalEngagement !== engagement
                Text("\(player.activeIndex)|\(rebuilt ? "rebuilt" : "original")")
                    .accessibilityIdentifier("moderation-item")
                if originalItem {
                    let range = 0...engagement.duration
                    let messages = engagement.messages(near: engagement.duration, lookback: engagement.duration, limit: .max)
                    let chat = messages.filter { $0.id == session.removedMessageID }.count
                    let reactions = engagement.reactions(in: range).filter { session.removedReactionIDs.contains($0.id) }.count
                    let polls = engagement.polls.filter { $0.id == session.removedPoll?.id }.count
                    Text("chat:\(chat) reactions:\(reactions) poll:\(polls)")
                        .accessibilityIdentifier("moderation-survivors")
                }
            }
            Text(session.status).accessibilityIdentifier("moderation-status")
                .lineLimit(2)
        }
        .font(.system(size: 11))
        .buttonStyle(.bordered)
        .tint(.white)
        .padding(8)
        .background(.black.opacity(0.8), in: .rect(cornerRadius: 10))
        .foregroundStyle(.white)
    }

    private var messages: [HMChatMessage] {
        engagement.messages(near: mediaTime, lookback: 20, limit: .max)
    }
}
#endif
