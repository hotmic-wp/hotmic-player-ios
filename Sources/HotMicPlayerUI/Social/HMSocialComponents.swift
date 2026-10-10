#if os(iOS)
import SwiftUI
import HotMicPlayer

/// Title, expandable description, community and host-routed hashtags, independent of playback controls.
public struct HMMetadataView: View {
    /// Current host-supplied social data, observed by the UI.
    public var content: HMSocialContent
    /// Host navigation callback for an activated tag.
    public var onHashtag: (String) -> Void
    @State private var expanded = false
    @Environment(\.dynamicTypeSize) private var dynamicType
    private let onExpand: (() -> Void)?
    @Environment(\.hmTheme) private var theme
    /// Creates this component with host-supplied data and actions.
    public init(content: HMSocialContent, onHashtag: @escaping (String) -> Void = { _ in }) {
        self.content = content; self.onHashtag = onHashtag; self.onExpand = nil
    }
    /// Routes expansion to a separate host presentation, keeping the original hashtag trailing closure compatible.
    public init(content: HMSocialContent, onExpand: @escaping () -> Void, onHashtag: @escaping (String) -> Void = { _ in }) {
        self.content = content; self.onHashtag = onHashtag; self.onExpand = onExpand
    }
    /// Renders the component using current observable data and environment theme.
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !dynamicType.isAccessibilitySize || expanded, let community = content.community { Text(community).font(theme.fonts.caption) }
            Text(content.title).font(theme.fonts.headline).lineLimit(dynamicType.isAccessibilitySize && !expanded ? 1 : 2)
            if !content.description.isEmpty || dynamicType.isAccessibilitySize {
                if !dynamicType.isAccessibilitySize || expanded {
                    Text(content.description).font(theme.fonts.body).lineLimit(expanded ? nil : 2)
                }
                Button(expanded ? "Show less" : "Show more") {
                    if let onExpand { onExpand() } else { expanded.toggle() }
                }
                    .font(theme.fonts.caption).frame(minHeight: 44)
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                    .accessibilityIdentifier("hm-description-toggle")
            }
            // Wrapping adapts to large accessibility sizes without truncating a tappable tag.
            if !dynamicType.isAccessibilitySize || expanded {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { tags }
                    VStack(alignment: .leading, spacing: 0) { tags }
                }
            }
        }
        .foregroundStyle(theme.colors.onVideo)
    }
    private var tags: some View {
        ForEach(Array(content.hashtags.enumerated()), id: \.offset) { _, tag in
            Button(tag.hasPrefix("#") ? tag : "#" + tag) { onHashtag(tag) }
                .font(theme.fonts.emphasis).frame(minHeight: 44)
                .accessibilityLabel("Hashtag \(tag)")
        }
    }
}

/// Ephemeral preview. Rotation/visibility is owned by the containing host or HMSocialOverlay.
/// Activation always opens the full comment sheet.
public struct HMCommentPreview: View {
    /// Preview comment selected by the host.
    public var comment: HMSocialComment
    /// Opens the full comment sheet when the preview is activated.
    public var onOpen: () -> Void
    @Environment(\.hmTheme) private var theme
    /// Creates this component with host-supplied data and actions.
    public init(comment: HMSocialComment, onOpen: @escaping () -> Void) { self.comment = comment; self.onOpen = onOpen }
    /// Renders the component using current observable data and environment theme.
    public var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 3) {
                Text(comment.author).font(theme.fonts.emphasis).lineLimit(1)
                Text(comment.text).font(theme.fonts.body).lineLimit(2)
            }
            .foregroundStyle(theme.colors.onVideo).padding(12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(theme.colors.scrim.opacity(0.7), in: RoundedRectangle(cornerRadius: theme.cornerRadius))
        }.buttonStyle(.plain)
        .accessibilityLabel("Open comments, \(comment.author): \(comment.text)")
        .accessibilityIdentifier("hm-comment-preview")
    }
}

/// Display-only unless a seek callback is provided. Uses the seekable window for live/DVR media too.
public struct HMProgressBar: View {
    /// Playback snapshot supplying seekable position and duration.
    public var snapshot: HMPlaybackSnapshot
    /// Optional seek action; nil keeps the bar display-only.
    public var onSeek: ((TimeInterval) -> Void)?
    /// Reports active drags and their termination to the playback interaction owner.
    public var onScrubbingChanged: (Bool) -> Void
    @State private var scrubbing = false
    @State private var scrubValue: Double?
    @Environment(\.hmTheme) private var theme
    /// Creates a display-only progress bar or an interactive native slider with a seek callback.
    public init(snapshot: HMPlaybackSnapshot, onSeek: ((TimeInterval) -> Void)? = nil,
                onScrubbingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.snapshot = snapshot; self.onSeek = onSeek; self.onScrubbingChanged = onScrubbingChanged
    }
    /// Renders continuous playback progress and optional seeking controls.
    public var body: some View {
        Group {
            if let onSeek {
                Slider(value: Binding(get: { scrubValue ?? snapshot.progress }, set: { progress in
                    if scrubbing { scrubValue = progress }
                    else { onSeek(snapshot.seekableStart + snapshot.seekableDuration * progress) } // VoiceOver adjustment
                }), onEditingChanged: { active in
                    if active { scrubValue = snapshot.progress; scrubbing = true; onScrubbingChanged(true) }
                    else {
                        let value = scrubValue ?? snapshot.progress
                        onSeek(snapshot.seekableStart + snapshot.seekableDuration * value)
                        scrubbing = false; scrubValue = nil; onScrubbingChanged(false)
                    }
                })
                .tint(theme.colors.onVideo).frame(height: 44)
                .accessibilityLabel("Video progress")
                .accessibilityValue(Text("\(Int((scrubValue ?? snapshot.progress) * 100)) percent"))
            } else {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.colors.track)
                        Capsule().fill(theme.colors.onVideo).frame(width: geometry.size.width * snapshot.progress)
                    }.frame(height: 3).frame(maxHeight: .infinity)
                }.frame(height: 12)
                .accessibilityElement(children: .ignore).accessibilityLabel("Video progress")
                .accessibilityValue(Text("\(Int(snapshot.progress * 100)) percent"))
            }
        }
        .accessibilityIdentifier("hm-social-progress")
        .onDisappear { if scrubbing { onScrubbingChanged(false) } }
    }
}

/// Lightweight, non-intercepting paused indicator. Video's public tap surface owns playback and accessibility.
public struct HMPlayPauseAffordance: View {
    /// Whether to show the paused playback affordance.
    public var isPaused: Bool
    @Environment(\.hmTheme) private var theme
    /// Creates this component with host-supplied data and actions.
    public init(isPaused: Bool) { self.isPaused = isPaused }
    /// Renders the component using current observable data and environment theme.
    public var body: some View {
        if isPaused {
            theme.image(for: .play).font(.system(size: 44, weight: .semibold))
                .foregroundStyle(theme.colors.onVideo).padding(20)
                .background(theme.colors.scrim.opacity(0.55), in: Circle())
                .allowsHitTesting(false).accessibilityRepresentation { EmptyView() }
                .accessibilityIdentifier("hm-paused-affordance")
        }
    }
}

/// A single event animates from the tap location into the rail. Reduce Motion uses a stationary icon flash.
public struct HMFireBurst: View {
    /// Shared Fire event identifier; changing it restarts the burst.
    public var event: Int
    /// Surface point at which the Fire burst begins.
    public var origin: CGPoint
    /// Rail icon center at which the burst resolves.
    public var target: CGPoint
    /// Cancel a running burst when its item or presentation becomes inactive. Re-enabling never replays it.
    public var isEnabled: Bool
    @Environment(\.hmTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var resolving = false
    @State private var visible = false
    @State private var animationTask: Task<Void, Never>?
    /// Creates this component with host-supplied data and actions.
    public init(event: Int, origin: CGPoint, target: CGPoint, isEnabled: Bool = true) {
        self.event = event; self.origin = origin; self.target = target; self.isEnabled = isEnabled
    }
    /// Renders the component using current observable data and environment theme.
    public var body: some View {
        theme.image(for: .fire)
            .font(.system(size: reduceMotion ? 30 : (resolving ? 27 : 72), weight: .bold))
            .foregroundStyle(theme.colors.accentSecondary)
            .scaleEffect(reduceMotion ? 1 : (resolving ? 1 : 1.25))
            .position(reduceMotion || resolving ? target : origin)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(false).accessibilityRepresentation { EmptyView() }
            .onChange(of: event) { _, value in
                animationTask?.cancel()
                guard isEnabled, value > 0 else { visible = false; return }
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) { resolving = false; visible = true }
                animationTask = Task { @MainActor in
                    do {
                        try await Task.sleep(for: .milliseconds(80))
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: theme.fireAnimationDuration)) { resolving = true }
                        try await Task.sleep(for: .seconds(max(0.1, theme.fireAnimationDuration)))
                        visible = false
                    } catch { }
                }
            }
            .onChange(of: isEnabled) { _, enabled in if !enabled { animationTask?.cancel(); visible = false } }
            .onDisappear { animationTask?.cancel(); visible = false }
    }
}
#endif
