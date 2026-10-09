#if os(iOS)
import SwiftUI
import HotMicPlayer

/// Recent chat near the playhead, newest at the bottom.
///
/// Shows the messages from the last `lookback` seconds of media time, so scrubbing
/// back rewinds the conversation too. New messages push older ones up and out
/// through a soft fade, which is the rail's auto-scroll; it deliberately doesn't
/// scroll by hand, because a vertical feed owns the vertical drag. With Reduce
/// Motion on, messages cross-fade instead of sliding.
///
/// Double-tap a message to react with `HMTheme.messageReaction`, when the source
/// supports message reactions. VoiceOver exposes the same as a named action.
public struct HMChatRail: View {

    private let engagement: HMEngagement
    private let mediaTime: TimeInterval
    private let lookback: TimeInterval
    private let limit: Int
    private let maxHeight: CGFloat?

    @Environment(\.hmTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Creates a chat rail at a media time.
    /// - Parameters:
    ///   - lookback: Seconds of history shown behind the playhead.
    ///   - limit: Most messages shown at once; halved at accessibility text sizes.
    ///   - maxHeight: Tallest the rail grows; older lines past it fade out at the top.
    public init(engagement: HMEngagement, mediaTime: TimeInterval, lookback: TimeInterval = 20, limit: Int = 5,
                maxHeight: CGFloat? = nil) {
        self.engagement = engagement
        self.mediaTime = mediaTime
        self.lookback = lookback
        self.limit = limit
        self.maxHeight = maxHeight
    }

    public var body: some View {
        // One query per body pass; this runs on every playback tick, and the
        // underlying lookup is a binary search over the timeline.
        let messages = engagement.messages(near: mediaTime, lookback: lookback,
                                           limit: typeSize.isAccessibilitySize ? max(1, limit / 2) : limit)
        let canReact = engagement.supports(.reactToMessage)

        VStack(alignment: .leading, spacing: 6) {
            ForEach(messages) { message in
                HMChatRow(message: message, canReact: canReact) {
                    react(to: message)
                }
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .bottomLeading)
        .clipped()
        // Older lines dissolve into the video rather than being cut off.
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.3)],
                           startPoint: .top, endPoint: .bottom)
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.28), value: messages.map(\.id))
        .animation(.snappy(duration: 0.2), value: messages.map(\.reactions))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat")
    }

    private func react(to message: HMChatMessage) {
        Task { try? await engagement.react(theme.messageReaction, toMessage: message.id) }
    }
}

/// One chat line: avatar, author, text and reaction counts.
struct HMChatRow: View {
    let message: HMChatMessage
    let canReact: Bool
    let onReact: () -> Void

    @Environment(\.hmTheme) private var theme
    @ScaledMetric(relativeTo: .subheadline) private var avatarSize: CGFloat = 26

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            HMAvatar(name: message.author, url: message.avatarURL, size: avatarSize)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(message.author)
                        .font(theme.fonts.emphasis)
                        .foregroundStyle(message.isOwn ? theme.colors.onVideo : theme.colors.author)
                    if message.delivery == .sending {
                        Text("Sending…")
                            .font(theme.fonts.caption)
                            .foregroundStyle(theme.colors.onVideoSecondary)
                    }
                }
                Text(message.text)
                    .font(theme.fonts.body)
                    .foregroundStyle(theme.colors.onVideo)
                    .fixedSize(horizontal: false, vertical: true)
                if !message.reactions.isEmpty { reactionChips }
            }
            .hmVideoLegible()
        }
        .padding(.vertical, message.isOwn ? 6 : 0)
        .padding(.horizontal, message.isOwn ? 8 : 0)
        .background {
            if message.isOwn {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.colors.accent.opacity(0.28))
            }
        }
        .opacity(message.delivery == .sending ? 0.75 : 1)
        .contentShape(.rect)
        .onTapGesture(count: 2) { if canReact { onReact() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAction(named: Text("React \(theme.messageReaction)")) { if canReact { onReact() } }
    }

    private var reactionChips: some View {
        HStack(spacing: 4) {
            ForEach(message.reactions.sorted { $0.value > $1.value }.prefix(3), id: \.key) { emoji, count in
                let own = message.ownReactions.contains(emoji)
                HStack(spacing: 3) {
                    Text(emoji).font(theme.fonts.caption)
                    Text(HMFormat.compact(count))
                        .font(theme.fonts.caption.monospacedDigit())
                        .foregroundStyle(theme.colors.onVideo)
                        .contentTransition(.numericText(value: Double(count)))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(own ? theme.colors.accent.opacity(0.55) : .black.opacity(0.32)))
                .overlay(Capsule().strokeBorder(own ? theme.colors.author.opacity(0.7) : .white.opacity(0.12), lineWidth: 0.5))
            }
        }
        .padding(.top, 2)
    }

    private var accessibilityText: Text {
        var text = "\(message.author): \(message.text)"
        if message.delivery == .sending { text += ". Sending" }
        if message.reactionCount > 0 {
            text += ". " + message.reactions.sorted { $0.value > $1.value }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        }
        return Text(text)
    }
}

/// Avatar image with a monogram fallback, tinted per author so the rail scans easily.
struct HMAvatar: View {
    let name: String
    let url: URL?
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [hue(0), hue(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(String(name.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).prefix(1)).uppercased())
                .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            if let url {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.clear }
                    .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private func hue(_ shift: Double) -> Color {
        let base = Double(HMFormat.stableHash(name) % 360) / 360
        return Color(hue: (base + shift).truncatingRemainder(dividingBy: 1), saturation: 0.55, brightness: 0.78)
    }
}
#endif
