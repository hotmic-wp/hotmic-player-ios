import SwiftUI
@_spi(Benchmark) import HotMicPlayer

/// Bottom-anchored chat rail. Shows the last few messages that fall behind the
/// playhead, so scrubbing rewinds the conversation too.
struct ChatRailView: View {

    let timeline: any HMStreamTimeline
    /// Playhead position on the *engagement* timeline, not the media clock.
    let offset: TimeInterval

    var body: some View {
        // Computed once per body pass: the ForEach and the animation trigger
        // both need it, and this runs on every playback tick.
        let messages = visibleMessages

        VStack(alignment: .leading, spacing: 5) {
            ForEach(messages) { message in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(message.author ?? "someone")
                        .font(DemoTheme.label(12, weight: .bold))
                        .foregroundStyle(DemoTheme.accent)
                    Text(message.text ?? "")
                        .font(DemoTheme.label(12))
                        .foregroundStyle(.white.opacity(0.92))
                }
                .videoLegible()
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: 250, alignment: .leading)
        .animation(.snappy(duration: 0.25), value: messages.map(\.id))
    }

    private var visibleMessages: [HMTimelineEvent] {
        let window = max(0, offset - 14)...max(0.01, offset)
        return timeline.events(in: window)
            .filter { $0.kind == .chat }
            .suffix(4)
    }
}
