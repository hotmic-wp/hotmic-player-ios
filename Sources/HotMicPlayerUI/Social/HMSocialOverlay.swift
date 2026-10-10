#if os(iOS)
import SwiftUI
import UIKit
import HotMicPlayer

/// Optional, ready-made social chrome built exclusively on public playback hooks.
/// Use HMSocialPlayerView for automatic surface wiring; when composing this alone, apply
/// hmSocialPlayback to the ancestor HMVerticalFeedView/HMPlayerView with the same state.
@MainActor public struct HMSocialOverlay: View {
    /// Host-owned playback engine; no second player is created.
    public let player: HMPlayer
    /// Media item whose overlay is being rendered.
    public let item: HMMediaItem
    /// Playback snapshot supplying seekable position and duration.
    public let snapshot: HMPlaybackSnapshot
    /// Host-owned observable data source for this item.
    public let data: any HMSocialDataSource
    /// State shared by the overlay and its ancestor playback modifier.
    public let state: HMSocialState
    /// Host navigation, preview, sheet and control configuration.
    public var options: HMSocialOptions
    /// Host event handlers for navigation, sharing, membership and sheets.
    public var callbacks: HMSocialCallbacks
    private var sidecar: AnyView?
    private var sidecarSize: CGSize = .zero
    private var replacementSheet: AnyView?
    @Environment(\.hmTheme) private var theme
    @Environment(\.hmFeedSafeArea) private var feedSafeArea
    @Environment(\.hmReservedRegions) private var reservations
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var previewHeight: CGFloat = 82
    @State private var previewIndex = 0
    @State private var previewVisible = false
    @State private var dragStart: CGFloat?
    @State private var keyboardTop: CGFloat?
    @State private var sidecarFrame = CGRect.zero

    /// Creates this component with host-supplied data and actions.
    public init(player: HMPlayer, item: HMMediaItem, snapshot: HMPlaybackSnapshot,
                data: any HMSocialDataSource, state: HMSocialState,
                options: HMSocialOptions = .init(), callbacks: HMSocialCallbacks = .init()) {
        self.player = player; self.item = item; self.snapshot = snapshot; self.data = data; self.state = state
        self.options = options; self.callbacks = callbacks
    }
    /// Host-provided sidecar, admitted only when its entire slot is free of reserved controls within video.
    public func sidecar<Content: View>(size: CGSize, @ViewBuilder content: () -> Content) -> Self {
        var copy = self; copy.sidecar = AnyView(content()); copy.sidecarSize = size; return copy
    }
    /// Replaces list/composer content while retaining the interactive sheet and squeezeback behavior.
    public func commentSheet<Content: View>(@ViewBuilder content: () -> Content) -> Self {
        var copy = self; copy.replacementSheet = AnyView(content()); return copy
    }
    private var current: Bool { player.currentItem?.id == item.id }
    private var adActive: Bool { player.adState.isActive }
    /// Renders the component using current observable data and environment theme.
    public var body: some View {
        GeometryReader { geometry in
            let safe = player.isFullscreen ? geometry.safeAreaInsets : EdgeInsets(
                top: max(feedSafeArea.top, geometry.safeAreaInsets.top),
                leading: max(feedSafeArea.leading, geometry.safeAreaInsets.leading),
                bottom: max(feedSafeArea.bottom, geometry.safeAreaInsets.bottom),
                trailing: max(feedSafeArea.trailing, geometry.safeAreaInsets.trailing))
            let nav = player.isFullscreen ? safe.bottom : safe.bottom + max(0, options.hostNavigationHeight)
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [.clear, theme.colors.scrim.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false).accessibilityHidden(true)
                if current {
                    HMPlayPauseAffordance(isPaused: snapshot.state == .paused)
                        .position(x: geometry.size.width / 2, y: max(safe.top + 50, snapshot.videoFrame.midY))
                }
                if !adActive && !state.isSheetOpen {
                    if player.isFullscreen {
                        fullscreenControls.padding(.bottom, nav + 12)
                    } else {
                        resting(size: geometry.size, safe: safe, nav: nav)
                        admittedSidecar(size: geometry.size, safe: safe, nav: nav)
                    }
                }
                if state.isSheetOpen && current && !adActive && !player.isFullscreen {
                    sheet(size: geometry.size, safe: safe, nav: nav, globalBottom: geometry.frame(in: .global).maxY)
                }
                if current && !adActive && !state.isSheetOpen && !player.isFullscreen {
                    HMFireBurst(event: state.fireItemID == item.id ? state.fireID : 0, origin: state.fireOrigin ?? state.fireTarget, target: state.fireTarget)
                }
                if let error = state.error, current, state.errorItemID == item.id {
                    Text(error).font(theme.fonts.caption).padding(8).background(.regularMaterial)
                        .padding(.top, safe.top + 12).frame(maxHeight: .infinity, alignment: .top)
                }
            }.coordinateSpace(name: "hm-social-overlay")
            .padding(.leading, 0)
        }
        .modifier(HMCurrentOverlayAccessibility(current: current))
        .task(id: current && !adActive && !state.isSheetOpen && !player.isFullscreen) {
            previewIndex = 0; previewVisible = false
            guard current, !adActive, !state.isSheetOpen, !player.isFullscreen else { return }
            // Candidates can arrive after the first comment page loads. Polling affects only preview state.
            while !Task.isCancelled {
                do {
                    if data.content.previewComments.isEmpty { try await Task.sleep(for: .milliseconds(250)); continue }
                    previewVisible = true
                    try await Task.sleep(for: .seconds(max(0.1, options.previewDuration)))
                    previewVisible = false
                    guard let interval = options.previewRotationInterval else { return }
                    try await Task.sleep(for: .seconds(max(0.5, interval - options.previewDuration)))
                    previewIndex += 1
                } catch { previewVisible = false; return }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            keyboardTop = frame.minY
        }
    }

    private func resting(size: CGSize, safe: EdgeInsets, nav: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom) {
                Spacer(minLength: 0)
                HMHitArea {
                    ScrollView {
                    VStack(alignment: .trailing, spacing: theme.railSpacing) {
                        HMActionRail(content: data.content, canFire: data.canFire, fireEvent: state.fireID,
                            onFire: { state.fire(at: nil, item: item, data: data, isAdActive: adActive, onToggle: callbacks.fireToggled) },
                            onComment: openComments, onShare: { callbacks.share(item) },
                            onFireFrame: { if current { state.fireTarget = CGPoint(x: $0.midX, y: $0.midY) } })
                        auxiliaryControls
                    }.frame(width: 144, alignment: .trailing)
                    }.scrollBounceBehavior(.basedOnSize).frame(width: 144, height: min(320, size.height * 0.34))
                }
            }
            if previewVisible, !data.content.previewComments.isEmpty {
                let comments = data.content.previewComments
                HMHitArea { HMCommentPreview(comment: comments[previewIndex % comments.count], onOpen: openComments).frame(height: previewHeight) }
            } else {
                Color.clear.frame(height: previewHeight).allowsHitTesting(false).accessibilityHidden(true)
            }
            HMHitArea {
                ScrollView {
                    HMMetadataView(content: data.content, onHashtag: callbacks.hashtagTapped)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.scrollBounceBehavior(.basedOnSize).frame(maxHeight: max(80, size.height * 0.26))
            }
            HMHitArea {
                HMProgressBar(snapshot: snapshot, onSeek: options.allowsScrubbing ? { time in if current { player.seek(to: time) } } : nil,
                    onScrubbingChanged: { if $0 { player.beginInteraction() } else { player.endInteraction() } })
            }
        }
        .padding(.leading, safe.leading + 16).padding(.trailing, safe.trailing + 12)
        .padding(.top, safe.top + 12).padding(.bottom, nav + 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
    private var auxiliaryControls: some View {
        HStack(spacing: 4) {
            if options.showsMute {
                control(player.isMuted ? .muted : .unmuted, label: player.isMuted ? "Unmute" : "Mute", value: player.isMuted ? "Muted" : "Audio on") { player.toggleMute() }
                    .accessibilityIdentifier("hm-social-mute")
            }
            if !player.availableCaptionLanguages.isEmpty {
                control(.captions, label: "Closed captions", value: player.captionsEnabled ? "On" : "Off") { player.captionsEnabled.toggle() }
                    .accessibilityIdentifier("hm-social-captions")
            }
            if !player.isFullscreen && (snapshot.aspectRatio ?? 0) > 1 {
                control(.fullscreen, label: "Enter fullscreen") { player.enterFullscreen() }
                    .accessibilityIdentifier("hm-social-fullscreen")
            }
        }
    }
    private var fullscreenControls: some View {
        HMHitArea {
            HStack {
                control(.play, label: snapshot.state == .playing ? "Pause" : "Play") { player.togglePlayPause() }
                auxiliaryControls
                control(.close, label: "Exit fullscreen") { player.exitFullscreen() }
            }.padding(8).background(theme.colors.scrim.opacity(0.65), in: Capsule())
        }
    }
    private func control(_ icon: HMTheme.Icon, label: String, value: String = "", action: @escaping () -> Void) -> some View {
        Button(action: action) { theme.image(for: icon).font(.title3).frame(minWidth: 44, minHeight: 44) }
            .buttonStyle(.plain).foregroundStyle(theme.colors.onVideo).hmVideoLegible()
            .accessibilityLabel(label).accessibilityValue(value)
    }
    private func openComments() {
        guard current, !adActive else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: theme.sheetAnimationDuration)) {
            state.openComments(item: item, height: options.sheetHeight, isAdActive: adActive, onChange: callbacks.sheetChanged)
        }
    }
    private func closeComments() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: theme.sheetAnimationDuration)) { state.closeComments() }
    }
    private func sheet(size: CGSize, safe: EdgeInsets, nav: CGFloat, globalBottom: CGFloat) -> some View {
        let keyboard = keyboardTop.map { max(0, globalBottom - $0) } ?? 0
        let bottom = max(nav, keyboard)
        let maximum = max(120, size.height - safe.top - bottom - 24)
        return VStack(spacing: 8) {
            HStack {
                Capsule().fill(.secondary).frame(width: 44, height: 5).frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 3)
                        .onChanged { value in
                            if dragStart == nil { dragStart = state.sheetHeight }
                            state.dragComments(to: min(maximum, max(60, (dragStart ?? options.sheetHeight) - value.translation.height)))
                        }.onEnded { value in
                            dragStart = nil
                            if state.sheetHeight < 140 || value.predictedEndTranslation.height > 200 { closeComments() }
                        })
                    .accessibilityElement().accessibilityLabel("Resize comments")
                    .accessibilityValue(Text("\(Int(state.sheetHeight)) points"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(named: Text("Expand comments")) { state.dragComments(to: min(maximum, state.sheetHeight + 60)) }
                    .accessibilityAction(named: Text("Shrink comments")) { state.dragComments(to: max(140, state.sheetHeight - 60)) }
                    .accessibilityIdentifier("hm-comment-handle")
                Button(action: closeComments) { theme.image(for: .close).frame(width: 44, height: 44) }
                    .accessibilityLabel("Close comments").accessibilityIdentifier("hm-close-comments")
            }.padding(.horizontal, 12)
            Text("Comments").font(theme.fonts.headline).accessibilityAddTraits(.isHeader)
            if let replacementSheet { replacementSheet }
            else { HMCommentSheet(data: data, onPosted: { callbacks.commentPosted(item, $0) }) }
        }
        .padding(.bottom, 12).frame(height: min(maximum, state.sheetHeight))
        .background(.regularMaterial, in: UnevenRoundedRectangle(topLeadingRadius: theme.cornerRadius, topTrailingRadius: theme.cornerRadius))
        .environment(\.colorScheme, .dark).padding(.bottom, bottom)
        .hmExcludedHitArea()
    }
    @ViewBuilder private func admittedSidecar(size: CGSize, safe: EdgeInsets, nav: CGFloat) -> some View {
        if let sidecar, sidecarSize.width > 0, sidecarSize.height > 0 {
            let bounds = CGRect(origin: .zero, size: size)
            let insets = HMVideoInsets(top: safe.top, left: safe.leading, bottom: safe.bottom, right: safe.trailing)
            let excluded = reservations.filter { $0 != sidecarFrame }
            let candidate = HMOverlayRegions.freeRects(videoFrame: snapshot.videoFrame, in: bounds,
                safeArea: insets, contentInsets: HMVideoInsets(bottom: nav), excluding: excluded)
                .sorted { $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY }
                .compactMap { region -> CGRect? in
                    let rect = CGRect(x: region.minX + 12, y: region.minY + 12, width: sidecarSize.width, height: sidecarSize.height)
                    return HMOverlayRegions.isFree(rect, videoFrame: snapshot.videoFrame, in: bounds,
                        safeArea: insets, contentInsets: HMVideoInsets(bottom: nav), excluding: excluded) ? rect : nil
                }.first
            if let rect = candidate {
                HMHitArea { sidecar.frame(width: rect.width, height: rect.height) }
                    .position(x: rect.midX, y: rect.midY).accessibilityIdentifier("hm-sidecar")
                    .onChange(of: rect, initial: true) { _, value in sidecarFrame = value }
            }
        }
    }
}

private struct HMCurrentOverlayAccessibility: ViewModifier {
    let current: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if current { content }
        else { content.accessibilityHidden(true) }
    }
}

/// SwiftUI surface + social overlay, with feed or inline playback. Retain data sources by item ID in the host.
@MainActor public struct HMSocialPlayerView: View {
    /// Public playback surface to compose with the social layer.
    public enum Surface {
        /// Snap-paging full-bleed vertical feed.
        case feed
        /// Non-paging player filling the host's constraints.
        case inline
    }
    private let player: HMPlayer
    private let surface: Surface
    private let options: HMSocialOptions
    private let callbacks: HMSocialCallbacks
    private let data: (HMMediaItem) -> any HMSocialDataSource
    private var sidecar: ((HMMediaItem) -> AnyView)?
    private var sidecarSize = CGSize.zero
    private var sheet: ((HMMediaItem) -> AnyView)?
    @State private var state = HMSocialState()
    /// Creates this component with host-supplied data and actions.
    public init(player: HMPlayer, surface: Surface = .feed, options: HMSocialOptions = .init(),
                callbacks: HMSocialCallbacks = .init(), data: @escaping (HMMediaItem) -> any HMSocialDataSource) {
        self.player = player; self.surface = surface; self.options = options; self.callbacks = callbacks; self.data = data
    }
    /// Supplies a per-item sidecar admitted through the public free-region API.
    public func sidecar<Content: View>(size: CGSize, @ViewBuilder content: @escaping (HMMediaItem) -> Content) -> Self {
        var copy = self; copy.sidecar = { AnyView(content($0)) }; copy.sidecarSize = size; return copy
    }
    /// Replaces the list/composer inside the interactive squeezeback shell.
    public func commentSheet<Content: View>(@ViewBuilder content: @escaping (HMMediaItem) -> Content) -> Self {
        var copy = self; copy.sheet = { AnyView(content($0)) }; return copy
    }
    private var extendsUnderSafeArea: Bool {
        switch surface { case .feed: return true; case .inline: return false }
    }
    /// Renders the selected surface with public social playback hooks.
    public var body: some View {
        Group {
            switch surface {
            case .feed: HMVerticalFeedView(player: player) { item, snapshot in overlay(item, snapshot) }
            case .inline: HMPlayerView(player: player, aspectRatio: nil) { item, snapshot in overlay(item, snapshot) }
            }
        }.hmSocialPlayback(player: player, state: state, options: options, extendsUnderSafeArea: extendsUnderSafeArea, data: data, callbacks: callbacks)
    }
    private func overlay(_ item: HMMediaItem, _ snapshot: HMPlaybackSnapshot) -> HMSocialOverlay {
        var overlay = HMSocialOverlay(player: player, item: item, snapshot: snapshot, data: data(item), state: state, options: options, callbacks: callbacks)
        if let sidecar { overlay = overlay.sidecar(size: sidecarSize) { sidecar(item) } }
        if let sheet { overlay = overlay.commentSheet { sheet(item) } }
        return overlay
    }
}

/// Embed as a UIKit child controller. Hosts own the player and data-source lifetimes.
@MainActor public final class HMSocialPlayerViewController: UIHostingController<AnyView> {
    /// Host-owned playback engine; no second player is created.
    public let player: HMPlayer
    /// Creates this component with host-supplied data and actions.
    public init(player: HMPlayer, surface: HMSocialPlayerView.Surface = .feed, options: HMSocialOptions = .init(),
                theme: HMTheme = .default, callbacks: HMSocialCallbacks = .init(),
                data: @escaping (HMMediaItem) -> any HMSocialDataSource) {
        self.player = player
        super.init(rootView: AnyView(HMSocialPlayerView(player: player, surface: surface, options: options, callbacks: callbacks, data: data).hmTheme(theme)))
    }
    /// Creates this component with host-supplied data and actions.
    public init(player: HMPlayer, content: HMSocialPlayerView, theme: HMTheme = .default) { self.player = player; super.init(rootView: AnyView(content.hmTheme(theme))) }
    @available(*, unavailable) required dynamic init?(coder aDecoder: NSCoder) { fatalError("Use init(player:)") }
}
#endif
