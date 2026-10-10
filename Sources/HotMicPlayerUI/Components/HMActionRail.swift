#if os(iOS)
import SwiftUI
import HotMicPlayer

/// The trailing column of actions: react, comment, share and mute.
///
/// Every button is optional. Pass the ones you want in `actions`; React and
/// Comment also disappear on their own when the source lacks the capability,
/// Share appears only with an `onShare` handler, and Mute only with an
/// `isMuted` binding. Tap React to send the theme's primary reaction; press and
/// hold to pick from `HMTheme.reactionPalette`.
///
/// Access on the main actor.
public struct HMActionRail: View {

    /// A button the rail can show.
    ///
    /// Configure this SwiftUI value on the main actor.
    public enum Action: Hashable, Sendable, CaseIterable {
        /// Stream reaction, with the item's reaction total.
        ///
        /// Configure this SwiftUI value on the main actor.
        case react
        /// Opens a composer through `onComment`.
        ///
        /// Configure this SwiftUI value on the main actor.
        case comment
        /// Placeholder the host wires to its own share sheet through `onShare`.
        ///
        /// Configure this SwiftUI value on the main actor.
        case share
        /// Sound toggle through the `isMuted` binding.
        ///
        /// Configure this SwiftUI value on the main actor.
        case mute
    }

    private let engagement: HMEngagement?
    private let actions: Set<Action>
    private let isMuted: Binding<Bool>?
    private let onComment: (() -> Void)?
    private let onShare: (() -> Void)?

    private var social: HMSocialContent?
    private var onFire: (() -> Void)?
    private var fireEvent = 0
    private var onFireFrame: ((CGRect) -> Void)?

    /// Backend-independent social rail. Shares the overlay's Fire event with the surface burst.
    public init(content: HMSocialContent, canFire: Bool = true, fireEvent: Int = 0,
                onFire: @escaping () -> Void, onComment: @escaping () -> Void,
                onShare: @escaping () -> Void, onFireFrame: ((CGRect) -> Void)? = nil) {
        self.engagement = nil; self.actions = []; self.isMuted = nil
        self.social = content; self.onFire = canFire ? onFire : nil; self.fireEvent = fireEvent
        self.onComment = onComment; self.onShare = onShare; self.onFireFrame = onFireFrame
    }

    @Environment(\.hmTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title2) private var iconSize: CGFloat = 27
    @State private var reactionTaps = 0
    @State private var showsPalette = false

    /// Creates the action rail.
    ///
    /// Access on the main actor.
    public init(engagement: HMEngagement, actions: Set<Action> = Set(Action.allCases), isMuted: Binding<Bool>? = nil,
                onComment: (() -> Void)? = nil, onShare: (() -> Void)? = nil) {
        self.engagement = engagement
        self.actions = actions
        self.isMuted = isMuted
        self.onComment = onComment
        self.onShare = onShare
    }

    /// Renders the component from current state when SwiftUI evaluates the view.
    /// Access on the main actor.
    public var body: some View {
        if let social {
            socialRail(social)
        } else if let engagement {
        VStack(spacing: theme.railSpacing) {
            if actions.contains(.react), engagement.supports(.reactToStream) { reactButton(engagement) }
            if actions.contains(.comment), engagement.supports(.sendChat), let onComment {
                railButton(symbol: theme.icons.comment, label: "Comment", action: onComment)
            }
            if actions.contains(.share), let onShare {
                railButton(symbol: theme.icons.share, label: "Share", action: onShare)
            }
            if actions.contains(.mute), let isMuted {
                railButton(symbol: isMuted.wrappedValue ? theme.icons.muted : theme.icons.unmuted,
                           label: isMuted.wrappedValue ? "Unmute" : "Mute") { isMuted.wrappedValue.toggle() }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: reactionTaps)
        }
    }

    private func reactButton(_ engagement: HMEngagement) -> some View {
        let total = engagement.reactionTotals.values.reduce(0, +)
        return VStack(spacing: 2) {
            Image(systemName: theme.icons.react)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [theme.colors.accentSecondary, theme.colors.accent],
                                                startPoint: .top, endPoint: .bottom))
                .symbolEffect(.bounce, options: .speed(1.4), value: reduceMotion ? 0 : reactionTaps)
            if total > 0 {
                Text(HMFormat.compact(total))
                    .font(theme.fonts.caption.monospacedDigit())
                    .foregroundStyle(theme.colors.onVideo)
                    .contentTransition(.numericText(value: Double(total)))
            }
        }
        .hmVideoLegible()
        .frame(minWidth: 52, minHeight: 52)
        .contentShape(.rect)
        .onTapGesture { send(theme.primaryReaction) }
        .onLongPressGesture(minimumDuration: 0.35) { showsPalette = true }
        .overlay(alignment: .trailing) {
            if showsPalette {
                palette
                    .offset(x: -60)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.6, anchor: .trailing).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0.25), value: showsPalette)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("React \(theme.primaryReaction)")
        .accessibilityValue(total > 0 ? "\(total) reactions" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { send(theme.primaryReaction) }
        .accessibilityActions {
            ForEach(theme.reactionPalette.dropFirst(), id: \.self) { emoji in
                Button("React \(emoji)") { send(emoji) }
            }
        }
    }

    private var palette: some View {
        HStack(spacing: 2) {
            ForEach(theme.reactionPalette, id: \.self) { emoji in
                Button {
                    send(emoji); showsPalette = false
                } label: {
                    Text(emoji).font(.title2).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("React \(emoji)")
            }
        }
        .padding(.horizontal, 6)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
        .fixedSize()
        .onDisappear { showsPalette = false }
        .task {
            // Dismiss on its own if the viewer walks away from it.
            try? await Task.sleep(for: .seconds(4)); showsPalette = false
        }
    }

    private func send(_ emoji: String) {
        reactionTaps += 1
        Task { try? await engagement?.react(emoji) }
    }

    private func socialRail(_ content: HMSocialContent) -> some View {
        VStack(spacing: theme.railSpacing) {
            if let onFire {
                socialButton(icon: .fire, label: "Fire", count: content.fireCount, action: onFire)
                    .foregroundStyle(content.isReacted ? theme.colors.accentSecondary : theme.colors.onVideo)
                    .accessibilityValue((content.isReacted ? "reacted" : "not reacted") + (content.fireCount.map { ", \($0) reactions" } ?? ""))
                    .accessibilityIdentifier("hm-fire")

            }
            if let onComment {
                socialButton(icon: .comment, label: "Comment", count: content.commentCount, action: onComment)
                    .accessibilityIdentifier("hm-comments")
            }
            if let onShare {
                socialButton(icon: .share, label: "Share", count: content.shareCount, action: onShare)
                    .accessibilityIdentifier("hm-share")
            }
        }.foregroundStyle(theme.colors.onVideo)
        .padding(6).background(theme.colors.scrim.opacity(0.7), in: RoundedRectangle(cornerRadius: theme.cornerRadius))
        .sensoryFeedback(.impact(weight: .light), trigger: fireEvent)
    }

    private func socialButton(icon: HMTheme.Icon, label: String, count: Int?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                theme.image(for: icon).font(.system(size: iconSize, weight: .semibold))
                    .background(GeometryReader { geometry in
                        if icon == .fire {
                            Color.clear.onChange(of: geometry.frame(in: .named("hm-social-overlay")), initial: true) { _, frame in
                                onFireFrame?(frame)
                            }
                        }
                    })
                if let count { Text(HMCountFormatter().string(from: count)).font(theme.fonts.caption.monospacedDigit()) }
            }.frame(minWidth: 52, minHeight: 52)
        }.buttonStyle(.plain).accessibilityLabel(label)
            .accessibilityValue(count.map { "\($0)" } ?? "")
    }

    private func railButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: iconSize * 0.9, weight: .semibold))
                .foregroundStyle(theme.colors.onVideo)
                .hmVideoLegible()
                .frame(minWidth: 52, minHeight: 52)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
#endif
