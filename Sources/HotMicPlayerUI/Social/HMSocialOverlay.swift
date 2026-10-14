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
    private var replacementRail: ((HMSocialRailContext) -> AnyView)?
    private var replacementMetadata: ((HMSocialMetadataContext) -> AnyView)?

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
    /// Replaces the rail; the context supplies shared Fire, comment, share and glyph-location hooks.
    public func actionRail<Content: View>(@ViewBuilder content: @escaping (HMSocialRailContext) -> Content) -> Self {
        var copy = self; copy.replacementRail = { AnyView(content($0)) }; return copy
    }
    /// Replaces metadata while retaining automatic hit-area reservation and host callbacks.
    public func metadata<Content: View>(@ViewBuilder content: @escaping (HMSocialMetadataContext) -> Content) -> Self {
        var copy = self; copy.replacementMetadata = { AnyView(content($0)) }; return copy
    }
    /// Only geometry enters chrome. Continuous playback observation belongs to the progress/status leaves.
    public var body: some View {
        HMSocialChrome(player: player, item: item, videoFrame: snapshot.videoFrame, aspectRatio: snapshot.aspectRatio,
            data: data, state: state, options: options, callbacks: callbacks, sidecar: sidecar, sidecarSize: sidecarSize,
            replacementSheet: replacementSheet, replacementRail: replacementRail, replacementMetadata: replacementMetadata)
    }
}

private struct HMSocialChrome: View {
    let player: HMPlayer
    let item: HMMediaItem
    let videoFrame: CGRect
    let aspectRatio: Double?
    let data: any HMSocialDataSource
    let state: HMSocialState
    let options: HMSocialOptions
    let callbacks: HMSocialCallbacks
    let sidecar: AnyView?
    let sidecarSize: CGSize
    let replacementSheet: AnyView?
    let replacementRail: ((HMSocialRailContext) -> AnyView)?
    let replacementMetadata: ((HMSocialMetadataContext) -> AnyView)?
    @Environment(\.hmTheme) private var theme
    @Environment(\.hmFeedSafeArea) private var feedSafeArea
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType
    @ScaledMetric(relativeTo: .body) private var railWidth: CGFloat = 144
    @State private var dragStart: CGFloat?
    @State private var expandedMetadata = false
    @State private var replayOwner = UUID()
    private var current: Bool { player.currentItem?.id == item.id }
    private var adActive: Bool { player.adState.isActive }
    var body: some View {
        GeometryReader { geometry in
            let safe = player.isFullscreen ? geometry.safeAreaInsets : EdgeInsets(
                top: max(feedSafeArea.top, geometry.safeAreaInsets.top), leading: max(feedSafeArea.leading, geometry.safeAreaInsets.leading),
                bottom: max(feedSafeArea.bottom, geometry.safeAreaInsets.bottom), trailing: max(feedSafeArea.trailing, geometry.safeAreaInsets.trailing))
            let nav = player.isFullscreen ? safe.bottom : safe.bottom + max(0, options.hostNavigationHeight)
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [.clear, theme.colors.scrim.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false).accessibilityHidden(true)
                HMSocialPausedLeaf(player: player, item: item)
                    .position(x: geometry.size.width / 2, y: max(safe.top + 50, videoFrame.midY))
                    .opacity(current ? 1 : 0)
                if player.isFullscreen {
                    HMSocialFullscreenControls(player: player, item: item, showsMute: options.showsMute)
                        .padding(.bottom, nav + 12).opacity(adActive ? 0 : 1).allowsHitTesting(!adActive)
                        .accessibilityHidden(!current || adActive)
                } else {
                    resting(safe: safe, nav: nav, width: geometry.size.width)
                        .opacity(state.isSheetOpen || (adActive && options.hidesMetadataDuringAds) ? 0 : 1)
                        .allowsHitTesting(!state.isSheetOpen && !(adActive && options.hidesMetadataDuringAds))
                    HMSocialSidecar(player: player, item: item, videoFrame: videoFrame, slot: sidecar, slotSize: sidecarSize, safe: safe, nav: nav)
                        .opacity(adActive || state.isSheetOpen ? 0 : 1).allowsHitTesting(!adActive && !state.isSheetOpen)
                        .accessibilityHidden(!current || adActive || state.isSheetOpen)
                }
                if state.isSheetOpen && current && !adActive && !player.isFullscreen { sheet }
                HMFireBurst(event: state.fireItemID == item.id ? state.fireID : 0,
                    origin: state.fireOrigin ?? state.fireTarget, target: state.fireTarget,
                    isEnabled: current && state.fireIsPositive && !adActive && !state.isSheetOpen && !player.isFullscreen)
                if let error = state.error, current, state.errorItemID == item.id {
                    Text(error).font(theme.fonts.caption).padding(8).background(.regularMaterial)
                        .padding(.top, safe.top + 12).frame(maxHeight: .infinity, alignment: .top)
                }
            }.coordinateSpace(name: "hm-social-overlay")
        }
        // Keep one visual hierarchy. Gate sections individually so an outer false value cannot expose hidden controls.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(current ? "hm-current-social-overlay" : "hm-warm-social-overlay")
        .task(id: current && player.isFeedVisible && !player.isFullscreen) { (data as? HMEngagementSocialAdapter)?.setReplayActive(current && player.isFeedVisible && !player.isFullscreen, for: replayOwner) }
        .onDisappear { (data as? HMEngagementSocialAdapter)?.setReplayActive(false, for: replayOwner) }
        .sheet(isPresented: $expandedMetadata) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let community = data.content.community { Text(community).font(theme.fonts.caption) }
                        Text(data.content.title).font(theme.fonts.headline)
                        Text(data.content.description).font(theme.fonts.body)
                        ForEach(data.content.hashtags, id: \.self) { tag in
                            Button(tag.hasPrefix("#") ? tag : "#" + tag) { callbacks.hashtagTapped(tag) }.frame(minHeight: 44)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding()
                }
                    .navigationTitle("About this video")
                    .toolbar { Button("Done") { expandedMetadata = false } }
            }.presentationDetents([.medium, .large]).hmTheme(theme).preferredColorScheme(.dark)
        }
    }
    private func resting(safe: EdgeInsets, nav: CGFloat, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 0)
                HMHitArea {
                    VStack(alignment: .trailing, spacing: theme.railSpacing) {
                        rail
                        HMSocialAuxiliaryControls(player: player, item: item, aspectRatio: aspectRatio, showsMute: options.showsMute)
                            .frame(height: 44)
                    }.frame(minWidth: min(railWidth, max(0, width - safe.leading - safe.trailing - 28)), alignment: .trailing)
                }.opacity(adActive ? 0 : 1).allowsHitTesting(!adActive).accessibilityHidden(!current || state.isSheetOpen || adActive)
            }
            if !dynamicType.isAccessibilitySize {
                HMSocialPreviewSlot(player: player, item: item, data: data, state: state, options: options,
                    eligible: current && !adActive && !state.isSheetOpen && !player.isFullscreen, onOpen: openComments)
            }
            HMHitArea {
                let context = HMSocialMetadataContext(content: data.content, hashtagTapped: callbacks.hashtagTapped, expand: { expandedMetadata = true })
                if let replacementMetadata { replacementMetadata(context) }
                else { HMMetadataView(content: context.content, onExpand: context.expand, onHashtag: context.hashtagTapped) }
            }.accessibilityHidden(!current || state.isSheetOpen || (adActive && options.hidesMetadataDuringAds))
            HMHitArea { HMSocialProgressLeaf(player: player, item: item, scrubbing: options.allowsScrubbing) }
                .accessibilityHidden(!current || state.isSheetOpen || (adActive && options.hidesMetadataDuringAds))
        }
        .padding(.leading, safe.leading + 16).padding(.trailing, safe.trailing + 12)
        .padding(.top, safe.top + 12).padding(.bottom, nav + 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
    @ViewBuilder private var rail: some View {
        let context = HMSocialRailContext(content: data.content, fireEvent: state.fireID, canFire: data.canFire,
            fire: { state.fire(at: nil, item: item, data: data, isAdActive: adActive, onToggle: callbacks.fireToggled) },
            openComments: openComments, share: { callbacks.share(item) }, fireFrameChanged: { frame in
                state.recordFireTarget(CGPoint(x: frame.midX, y: frame.midY), for: item.id)
            })
        if let replacementRail { replacementRail(context) }
        else { HMActionRail(content: context.content, canFire: context.canFire, fireEvent: state.fireID,
            onFire: context.fire, onComment: context.openComments, onShare: context.share, onFireFrame: context.fireFrameChanged) }
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
    private var sheet: some View {
        VStack(spacing: 8) {
            HStack {
                Capsule().fill(.secondary).frame(width: 44, height: 5).frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                        if dragStart == nil { dragStart = state.sheetHeight }
                        state.dragComments(to: max(60, (dragStart ?? options.sheetHeight) - value.translation.height))
                    }.onEnded { value in
                        dragStart = nil
                        if state.sheetHeight < 140 || value.predictedEndTranslation.height > 200 { closeComments() }
                    })
                    .accessibilityElement().accessibilityLabel("Resize comments")
                    .accessibilityValue(Text("\(Int(state.sheetHeight)) points")).accessibilityAddTraits(.isButton)
                    .accessibilityAction(named: Text("Expand comments")) { state.dragComments(to: state.sheetHeight + 60) }
                    .accessibilityAction(named: Text("Shrink comments")) { state.dragComments(to: max(140, state.sheetHeight - 60)) }
                    .accessibilityIdentifier("hm-comment-handle")
                Button(action: closeComments) { theme.image(for: .close).font(.system(size: 22)).frame(width: 44, height: 44) }
                    .accessibilityLabel("Close comments").accessibilityIdentifier("hm-close-comments")
            }.padding(.horizontal, 12)
            Text("Comments").font(theme.fonts.headline).accessibilityAddTraits(.isHeader)
            if let replacementSheet { replacementSheet }
            else { HMCommentSheet(data: data, onPosted: { callbacks.commentPosted(item, $0) }) }
        }
        .padding(.bottom, 12).frame(height: state.sheetHeight)
        .background(.regularMaterial, in: UnevenRoundedRectangle(topLeadingRadius: theme.cornerRadius, topTrailingRadius: theme.cornerRadius))
        .environment(\.colorScheme, .dark).padding(.bottom, state.sheetBottomInset)
        .hmExcludedHitArea()
    }
}

/// Each time-varying leaf observes the public snapshot itself; chrome receives only stable geometry.
private struct HMSocialProgressLeaf: View {
    let player: HMPlayer
    let item: HMMediaItem
    let scrubbing: Bool
    var body: some View {
        HMProgressBar(snapshot: player.snapshot(for: item), onSeek: scrubbing ? { time in
            if player.currentItem?.id == item.id { player.seek(to: time) }
        } : nil, onScrubbingChanged: { if $0 { player.beginInteraction() } else { player.endInteraction() } })
    }
}
private struct HMSocialPausedLeaf: View {
    let player: HMPlayer
    let item: HMMediaItem
    var body: some View { HMPlayPauseAffordance(isPaused: player.snapshot(for: item).state == .paused) }
}
private struct HMSocialAuxiliaryControls: View {
    let player: HMPlayer
    let item: HMMediaItem
    let aspectRatio: Double?
    let showsMute: Bool
    var body: some View {
        HStack(spacing: 4) {
            if showsMute {
                HMSocialControl(icon: player.isMuted ? .muted : .unmuted, label: player.isMuted ? "Unmute" : "Mute", value: player.isMuted ? "Muted" : "Audio on") { player.toggleMute() }
                    .accessibilityIdentifier("hm-social-mute")
            }
            // Warm pages know sidecar caption tracks before becoming current. The slot height is always reserved.
            if !item.captionSources.isEmpty || (player.currentItem?.id == item.id && !player.availableCaptionLanguages.isEmpty) {
                HMSocialControl(icon: .captions, label: "Closed captions", value: player.captionsEnabled ? "On" : "Off") { player.captionsEnabled.toggle() }
                    .accessibilityIdentifier("hm-social-captions")
            }
            if !player.isFullscreen && (aspectRatio ?? 0) > 1 {
                HMSocialControl(icon: .fullscreen, label: "Enter fullscreen") { player.enterFullscreen() }.accessibilityIdentifier("hm-social-fullscreen")
            }
        }
    }
}
private struct HMSocialFullscreenControls: View {
    let player: HMPlayer
    let item: HMMediaItem
    let showsMute: Bool
    var body: some View {
        HMHitArea {
            HStack {
                let playing = player.snapshot(for: item).state == .playing
                HMSocialControl(icon: playing ? .pause : .play, label: playing ? "Pause" : "Play") { player.togglePlayPause() }
                HMSocialAuxiliaryControls(player: player, item: item, aspectRatio: nil, showsMute: showsMute)
                HMSocialControl(icon: .close, label: "Exit fullscreen") { player.exitFullscreen() }
            }.padding(8).background(.black.opacity(0.65), in: Capsule())
        }
    }
}
private struct HMSocialControl: View {
    let icon: HMTheme.Icon
    let label: String
    var value = ""
    let action: () -> Void
    @Environment(\.hmTheme) private var theme
    var body: some View {
        Button(action: action) { theme.image(for: icon).font(.system(size: 22)).frame(minWidth: 44, minHeight: 44) }
            .buttonStyle(.plain).foregroundStyle(theme.colors.onVideo).accessibilityLabel(label).accessibilityValue(value)
    }
}

private struct HMSocialPreviewSlot: View {
    let player: HMPlayer
    let item: HMMediaItem
    let data: any HMSocialDataSource
    let state: HMSocialState
    let options: HMSocialOptions
    let eligible: Bool
    let onOpen: () -> Void
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 96
    @State private var index = 0
    @State private var visible = false
    private struct Schedule: Equatable {
        let eligible: Bool
        let ready: Bool
        let comments: [String]
        let duration: TimeInterval
        let rotation: TimeInterval?
    }
    var body: some View {
        let comments = data.content.previewComments
        let schedule = Schedule(eligible: eligible, ready: player.snapshot(for: item).timeToFirstFrame != nil,
            comments: comments.map(\.id), duration: options.previewDuration, rotation: options.previewRotationInterval)
        HMCommentPreview(comment: comments.isEmpty ? HMSocialComment(id: "", author: "", text: "") : comments[index % comments.count], onOpen: onOpen)
            .frame(height: height)
            .background { if visible && eligible { Color.clear.hmExcludedHitArea() } }
            .opacity(visible && eligible ? 1 : 0).allowsHitTesting(visible && eligible)
            .accessibilityHidden(!visible || !eligible)
            .task(id: schedule) {
                visible = false
                guard schedule.eligible, schedule.ready, !comments.isEmpty else { return }
                if schedule.rotation == nil, !state.claimPreview(for: item.id) { return }
                await Task.yield() // Begin ephemeral UI work after the first displayed frame.
                index = 0
                while !Task.isCancelled {
                    do {
                        visible = true
                        try await Task.sleep(for: .seconds(max(0.1, schedule.duration)))
                        visible = false
                        guard let interval = schedule.rotation else { return }
                        try await Task.sleep(for: .seconds(max(0.5, interval - schedule.duration)))
                        index += 1
                    } catch { return }
                }
            }
    }
}

private struct HMSocialSidecar: View {
    let player: HMPlayer
    let item: HMMediaItem
    let videoFrame: CGRect
    let slot: AnyView?
    let slotSize: CGSize
    let safe: EdgeInsets
    let nav: CGFloat
    @Environment(\.hmReservedRegions) private var reservations
    @State private var ownFrame = CGRect.zero
    @State private var placementCache = PlacementCache()
    private struct Placement: Equatable {
        let bounds: CGRect
        let video: CGRect
        let safe: HMVideoInsets
        let nav: CGFloat
        let size: CGSize
        let excluded: [CGRect]
    }
    // A non-observable cache keeps geometry synchronous without recalculating on progress ticks.
    private final class PlacementCache {
        var inputs: Placement?
        var rect: CGRect?
        func resolve(_ input: Placement) -> CGRect? {
            if inputs == input { return rect }
            inputs = input
            rect = HMOverlayRegions.freeRects(videoFrame: input.video, in: input.bounds,
                safeArea: input.safe, contentInsets: HMVideoInsets(bottom: input.nav), excluding: input.excluded)
                .sorted { $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY }
                .compactMap { region -> CGRect? in
                    let rect = CGRect(x: region.minX + 12, y: region.minY + 12, width: input.size.width, height: input.size.height)
                    return HMOverlayRegions.isFree(rect, videoFrame: input.video, in: input.bounds,
                        safeArea: input.safe, contentInsets: HMVideoInsets(bottom: input.nav), excluding: input.excluded) ? rect : nil
                }.first
            return rect
        }
    }
    var body: some View {
        GeometryReader { geometry in
            if let slot, slotSize.width > 0, slotSize.height > 0,
               player.currentItem?.id == item.id, player.snapshot(for: item).timeToFirstFrame != nil {
                let bounds = CGRect(origin: .zero, size: geometry.size)
                let insets = HMVideoInsets(top: safe.top, left: safe.leading, bottom: safe.bottom, right: safe.trailing)
                let excluded = reservations.filter { !approximatelyEqual($0, ownFrame) }
                let inputs = Placement(bounds: bounds, video: videoFrame, safe: insets, nav: nav,
                    size: slotSize, excluded: excluded)
                let candidate = placementCache.resolve(inputs)
                if let rect = candidate {
                    HMHitArea { slot.frame(width: rect.width, height: rect.height) }
                        .position(x: rect.midX, y: rect.midY).accessibilityIdentifier("hm-sidecar")
                }
                Color.clear.allowsHitTesting(false).onChange(of: candidate, initial: true) { _, rect in
                    if let rect, !approximatelyEqual(rect, ownFrame) { ownFrame = rect }
                }
            }
        }
    }
    private func approximatelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
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
    /// Host-owned player used by this surface and UIKit embedding.
    public let player: HMPlayer
    private let surface: Surface
    private let options: HMSocialOptions
    private let callbacks: HMSocialCallbacks
    private let data: (HMMediaItem) -> any HMSocialDataSource
    private var sidecar: ((HMMediaItem) -> AnyView)?
    private var sidecarSize = CGSize.zero
    private var sheet: ((HMMediaItem) -> AnyView)?
    private var rail: ((HMMediaItem, HMSocialRailContext) -> AnyView)?
    private var metadataSlot: ((HMMediaItem, HMSocialMetadataContext) -> AnyView)?
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
    /// Replaces the action rail for each item while preserving shared social actions.
    public func actionRail<Content: View>(@ViewBuilder content: @escaping (HMMediaItem, HMSocialRailContext) -> Content) -> Self {
        var copy = self; copy.rail = { AnyView(content($0, $1)) }; return copy
    }
    /// Replaces metadata for each item while preserving host hashtag and expansion actions.
    public func metadata<Content: View>(@ViewBuilder content: @escaping (HMMediaItem, HMSocialMetadataContext) -> Content) -> Self {
        var copy = self; copy.metadataSlot = { AnyView(content($0, $1)) }; return copy
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
        if let rail { overlay = overlay.actionRail { rail(item, $0) } }
        if let metadataSlot { overlay = overlay.metadata { metadataSlot(item, $0) } }
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
    public init(content: HMSocialPlayerView, theme: HMTheme = .default) {
        self.player = content.player; super.init(rootView: AnyView(content.hmTheme(theme)))
    }
    @available(*, unavailable) required dynamic init?(coder aDecoder: NSCoder) { fatalError("Use init(player:)") }
}
#endif
