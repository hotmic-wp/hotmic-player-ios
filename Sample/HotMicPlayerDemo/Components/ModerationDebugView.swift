#if DEBUG
import SwiftUI
@_spi(Benchmark) import HotMicPlayer

/// Sample-only mock moderation controls, enabled with `--hm-moderation 1`.
struct ModerationDebugView: View {
    let engagement: HMEngagement
    let mediaTime: TimeInterval
    @State private var status = "Ready"

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Mock moderation").font(.caption.bold())
            HStack {
                Button("Delete newest") {
                    if let message = messages.last(where: { !$0.isOwn }) {
                        engagement.removeMessage(id: message.id)
                        status = "Deleted newest: \(message.author): \(message.text)"
                    } else { status = "No incoming chat" }
                }
                .accessibilityIdentifier("moderation-newest")
                Button("Delete mine") {
                    let time = engagement.duration > 0 ? engagement.duration : mediaTime
                    if let message = engagement.messages(near: time, lookback: time, limit: .max).last(where: \.isOwn) {
                        engagement.removeMessage(id: message.id)
                        status = "Deleted mine: \(message.text)"
                    } else { status = "No own chat" }
                }
                .accessibilityIdentifier("moderation-own")
            }
            HStack {
                Button("Delete poll") {
                    if let poll = engagement.polls(at: mediaTime).first {
                        engagement.removePoll(id: poll.id)
                        status = "Deleted poll: \(poll.question)"
                    } else { status = "No active poll" }
                }
                .accessibilityIdentifier("moderation-poll")
                Button("Delete peak reactions") {
                    guard let marker = engagement.markers.first else { status = "No peak"; return }
                    // Clear the events feeding this peak, using the same public stream API.
                    let halfWidth = engagement.duration * 0.08
                    for reaction in engagement.reactions(in: max(0, marker.offset - halfWidth)...(marker.offset + halfWidth)) {
                        engagement.removeReaction(id: reaction.id)
                    }
                    status = "Deleted peak reactions"
                }
                .accessibilityIdentifier("moderation-peak")
            }
            Text(status).accessibilityIdentifier("moderation-status")
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
