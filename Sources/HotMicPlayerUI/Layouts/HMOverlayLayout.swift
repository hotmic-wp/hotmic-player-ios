#if os(iOS)
import Combine
import SwiftUI
import UIKit
import HotMicPlayer

/// Full-screen vertical video with engagement overlaid, TikTok-style.
///
/// Bottom-leading: the poll card, chat near the playhead and the item's author and
/// title. Trailing: the action rail, with reactions rising above it. Along the
/// bottom: the engagement scrubber. A tap on the video toggles playback. Comment
/// opens a composer above the keyboard; the new message lands at the current
/// media time. Everything sits on a soft bottom scrim, so it stays legible over
/// bright video, and the top of the frame is left clear for host chrome.
///
/// ```swift
/// HMVerticalFeedView(player: player, layout: HMOverlayLayout.self)
/// ```
///
/// Configure it with `.hmOverlayOptions(_:)` and restyle it with `.hmTheme(_:)`,
/// or build it directly in your own overlay closure with explicit options.
///
/// Access on the main actor.
public struct HMOverlayLayout: HMEngagementLayout {

    /// What the layout shows. Hidden parts aren't built at all.
    ///
    /// Configure this SwiftUI value on the main actor.
    public struct Options {
        /// Chat rail.
        ///
        /// Configure this SwiftUI value on the main actor.
        public var showsChat = true
        /// Poll card.
        ///
        /// Configure this SwiftUI value on the main actor.
        public var showsPolls = true
        /// Floating reactions on the current item.
        ///
        /// Configure this SwiftUI value on the main actor.
        public var showsFloatingReactions = true
        /// Engagement scrubber.
        ///
        /// Configure this SwiftUI value on the main actor.
        public var showsScrubber = true
        /// Item author and title.
        ///
        /// Configure this SwiftUI value on the main actor.
        public var showsMetadata = true
        /// Tap to play/pause, the play/pause glyph and the buffering spinner.
        ///
        /// Configure this SwiftUI value on the main actor.
        public var handlesPlayback = true
        /// Action rail buttons. Share also needs `onShare`.
        ///
        /// Configure this SwiftUI value on the main actor.
        public var actions: Set<HMActionRail.Action> = Set(HMActionRail.Action.allCases)
        /// Share placeholder handler; Share is hidden without one.
        ///
        /// Configure this SwiftUI value on the main actor.
        public var onShare: ((HMMediaItem) -> Void)?
        /// Seconds of chat history behind the playhead.
        ///
        /// Configure this SwiftUI value on the main actor.
        public var chatLookback: TimeInterval = 20
        /// Most chat messages on screen.
        ///
        /// Configure this SwiftUI value on the main actor.
        public var chatLimit = 5
        /// Extra space beyond the safe area, for example to clear host chrome at the top.
        ///
        /// Configure this SwiftUI value on the main actor.
        public var contentInsets = EdgeInsets(top: 56, leading: 16, bottom: 6, trailing: 8)

        /// Everything on, Share hidden until `onShare` is set.
        ///
        /// Configure this SwiftUI value on the main actor.
        public init() {}

        /// The default options.
        ///
        /// Configure this SwiftUI value on the main actor.
        public static var `default`: Options { Options() }
    }

    private let context: HMEngagementContext
    private let explicitOptions: Options?

    @Environment(\.hmTheme) private var theme
    @Environment(\.hmOverlayOptions) private var environmentOptions
    @Environment(\.hmFeedSafeArea) private var safeArea
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isComposing = false
    @State private var isScrubbing = false
    @State private var keyboardOverlap: CGFloat = 0

    /// Creates the layout with options from the environment.
    ///
    /// Access on the main actor.
    public init(context: HMEngagementContext) {
        self.context = context
        self.explicitOptions = nil
    }

    /// Creates the layout with explicit options.
    ///
    /// Access on the main actor.
    public init(context: HMEngagementContext, options: Options) {
        self.context = context
        self.explicitOptions = options
    }

    /// Creates the layout inside your own overlay closure.
    ///
    /// Access on the main actor.
    public init(player: HMPlayer, item: HMMediaItem, snapshot: HMPlaybackSnapshot, options: Options? = nil) {
        self.context = HMEngagementContext(player: player, item: item, snapshot: snapshot)
        self.explicitOptions = options
    }

    private var options: Options { explicitOptions ?? environmentOptions }
    private var engagement: HMEngagement { context.engagement }
    private var mediaTime: TimeInterval { context.mediaTime }

    /// Renders the component from current state when SwiftUI evaluates the view.
    /// Access on the main actor.
    public var body: some View {
        let isCurrent = context.isCurrent
        GeometryReader { proxy in
            ZStack {
                scrim
                tapLayer

                // Under the overlay content, and above centre where the bottom
                // stack can't cover it.
                if options.handlesPlayback {
                    playbackIndicators(isCurrent: isCurrent)
                        .offset(y: -proxy.size.height * 0.12)
                }

                if options.showsFloatingReactions && isCurrent {
                    HMFloatingReactions(engagement: engagement, mediaTime: mediaTime,
                                        isPlaying: context.snapshot.state == .playing,
                                        trailingInset: safeArea.trailing + options.contentInsets.trailing + 26,
                                        launchHeight: 0.52)
                }

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    if isComposing {
                        composing(height: proxy.size.height)
                    } else {
                        resting(height: proxy.size.height)
                    }
                }
                .padding(.top, safeArea.top + options.contentInsets.top)
                .padding(.leading, safeArea.leading + options.contentInsets.leading)
                .padding(.trailing, safeArea.trailing + options.contentInsets.trailing)
                .padding(.bottom, isComposing && keyboardOverlap > 0
                         ? keyboardOverlap + 8
                         : safeArea.bottom + options.contentInsets.bottom)

            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                keyboardOverlap = max(0, proxy.frame(in: .global).maxY - frame.minY)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .snappy(duration: 0.28), value: isComposing)
        .animation(.easeOut(duration: 0.25), value: keyboardOverlap)
        .animation(.snappy(duration: 0.2), value: context.snapshot.state == .paused)
        .onChange(of: isCurrent) { _, current in
            guard !current else { return }
            isComposing = false
            endScrubbing()
        }
        .onChange(of: isScrubbing) { _, scrubbing in
            // Scrubbing is an interaction: automatic failure skips wait for it to end. The scrubber
            // reports false on cancellation too, because its drag lives in gesture state.
            if scrubbing { context.player.beginInteraction() } else { context.player.endInteraction() }
        }
        // A cell torn down mid-drag gets no gesture callback at all.
        .onDisappear { endScrubbing() }
    }

    // MARK: - Regions

    /// Soft bottom gradient, tall enough to carry chat, plus a faint top one for host chrome.
    private var scrim: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [theme.colors.scrim.opacity(0.28), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 140)
            Spacer(minLength: 0)
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: theme.colors.scrim.opacity(0.25), location: 0.35),
                                   .init(color: theme.colors.scrim.opacity(isComposing ? 0.78 : 0.62), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .containerRelativeFrame(.vertical) { height, _ in height * 0.55 }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var tapLayer: some View {
        Color.clear
            .contentShape(.rect)
            .onTapGesture {
                if isComposing { dismissComposer(); return }
                guard options.handlesPlayback, context.isCurrent else { return }
                context.player.togglePlayPause()
            }
            .accessibilityElement()
            .accessibilityLabel(isComposing ? "Close composer" : (context.snapshot.state == .playing ? "Pause" : "Play"))
            .accessibilityAddTraits(.isButton)
            .accessibilitySortPriority(-1)
            .accessibilityHidden(!isComposing && (!options.handlesPlayback || !context.isCurrent))
    }

    private func resting(height: CGFloat) -> some View {
        // A poll takes the chat's place rather than stacking on top of a full rail.
        let pollVisible = options.showsPolls && !engagement.polls(at: mediaTime).isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 10) {
                    if options.showsPolls {
                        HMPollCard(engagement: engagement, mediaTime: mediaTime)
                    }
                    if options.showsChat {
                        HMChatRail(engagement: engagement, mediaTime: mediaTime, lookback: options.chatLookback,
                                   limit: pollVisible ? min(2, options.chatLimit) : options.chatLimit,
                                   maxHeight: height * (pollVisible ? 0.14 : 0.24))
                    }
                    if options.showsMetadata { metadata }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HMActionRail(engagement: engagement, actions: options.actions,
                             isMuted: Binding(get: { context.player.isMuted }, set: { context.player.isMuted = $0 }),
                             onComment: { isComposing = true },
                             onShare: options.onShare.map { share in { share(context.item) } })
            }
            if options.showsScrubber {
                HMEngagementScrubber(engagement: engagement, snapshot: context.snapshot,
                                     // `seek(to:)` acts on the current item; a drag that ends after
                                     // its cell scrolled away must not move the new item.
                                     onSeek: { time in if context.isCurrent { context.player.seek(to: time) } },
                                     onScrubbingChanged: { isScrubbing = $0 })
                    .padding(.trailing, 8)
            }
        }
        .transition(.opacity)
    }

    private func composing(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if options.showsChat {
                HMChatRail(engagement: engagement, mediaTime: mediaTime, lookback: options.chatLookback,
                           limit: options.chatLimit, maxHeight: height * 0.22)
                    .padding(.trailing, 56)
            }
            HMComposer(engagement: engagement, onSent: dismissComposer, onDismiss: dismissComposer)
                .padding(.trailing, 8)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let author = context.item.author {
                Text(author)
                    .font(theme.fonts.emphasis)
                    .foregroundStyle(theme.colors.onVideo)
            }
            if let title = context.item.title {
                Text(title)
                    .font(theme.fonts.body)
                    .foregroundStyle(theme.colors.onVideoSecondary)
                    .lineLimit(2)
            }
        }
        .hmVideoLegible()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func playbackIndicators(isCurrent: Bool) -> some View {
        if isCurrent && (context.snapshot.state == .buffering || context.snapshot.state == .loading) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(theme.colors.onVideo)
                .controlSize(.large)
                .transition(.opacity)
                .accessibilityLabel("Loading")
        }
        // Stays while paused, so a paused frame never looks like a stall.
        if isCurrent && context.snapshot.state == .paused {
            Image(systemName: "play.fill")
                .font(.system(size: 50))
                .foregroundStyle(theme.colors.onVideo.opacity(0.75))
                .shadow(color: .black.opacity(0.35), radius: 12)
                .transition(reduceMotion ? .opacity : .scale(scale: 1.4).combined(with: .opacity))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func endScrubbing() {
        guard isScrubbing else { return }
        isScrubbing = false
        context.player.endInteraction()
    }

    private func dismissComposer() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        isComposing = false
    }
}

private struct HMOverlayOptionsKey: EnvironmentKey {
    static let defaultValue = HMOverlayLayout.Options()
}

public extension EnvironmentValues {
    /// Options read by `HMOverlayLayout` when none are passed explicitly.
    ///
    /// Configure this SwiftUI value on the main actor.
    var hmOverlayOptions: HMOverlayLayout.Options {
        get { self[HMOverlayOptionsKey.self] }
        set { self[HMOverlayOptionsKey.self] = newValue }
    }
}

public extension View {
    /// Configures every `HMOverlayLayout` inside this view.
    ///
    /// Access on the main actor.
    func hmOverlayOptions(_ options: HMOverlayLayout.Options) -> some View { environment(\.hmOverlayOptions, options) }
}
#endif
