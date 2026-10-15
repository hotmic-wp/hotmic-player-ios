#if os(iOS)
import SwiftUI
import UIKit
import Observation
import HotMicPlayer

/// Shared between HMSocialOverlay and hmSocialPlayback. One Fire event drives both burst and rail.
@MainActor @Observable public final class HMSocialState {
    /// Preferred sheet height in points, clamped to the available viewport.
    public private(set) var sheetHeight: CGFloat = 0
    /// Monotonically increasing positive-reaction event shared by burst and rail.
    public private(set) var fireID = 0
    /// Latest surface tap location, or the rail target for a rail activation.
    public private(set) var fireOrigin: CGPoint?
    /// Center of the current rail icon in surface coordinates.
    public var fireTarget: CGPoint = .zero
    /// Latest Fire action failure, suitable for displaying to the viewer.
    public private(set) var error: String?
    var fireItemID: String?
    var fireIsPositive = false
    var errorItemID: String?
    /// Maximum sheet height after viewport, safe-area and keyboard obstruction are accounted for.
    public private(set) var maximumSheetHeight: CGFloat = .greatestFiniteMagnitude
    /// Distance from the surface bottom to the sheet, including host navigation or keyboard.
    public private(set) var sheetBottomInset: CGFloat = 0
    /// Rest positions of a snapped sheet. A continuous sheet reports `squeezed` whenever it is open.
    public enum SheetPosition: String, Sendable {
        /// The sheet rests at its squeezed height and video plays above it.
        case squeezed
        /// The sheet covers the viewport below the top safe area; the kit pauses playback here.
        case expanded
    }
    /// Where the open sheet rests; nil while closed. A drag keeps the previous rest position until it is released.
    public private(set) var sheetPosition: SheetPosition?
    /// Snapped rest height of the squeezed position; nil keeps continuous dragging.
    public private(set) var squeezedSheetHeight: CGFloat?
    @ObservationIgnored private var previewedItems: Set<String> = []
    @ObservationIgnored private var fireTargets: [String: CGPoint] = [:]
    func recordFireTarget(_ point: CGPoint, for itemID: String) { fireTargets[itemID] = point }
    private var requestID = 0
    private var sheetItem: HMMediaItem?
    @ObservationIgnored private var sheetCallback: ((HMMediaItem, Bool) -> Void)?
    /// Creates this component with host-supplied data and actions.
    public init() {}
    /// Opens the default or replacement sheet unless an ad or another sheet is active.
    public func openComments(item: HMMediaItem, height: CGFloat, isAdActive: Bool,
                             onChange: @escaping (HMMediaItem, Bool) -> Void = { _, _ in }) {
        guard !isAdActive, sheetItem == nil else { return }
        sheetItem = item; sheetCallback = onChange
        sheetHeight = min(maximumSheetHeight, max(1, squeezedSheetHeight ?? height)); sheetPosition = .squeezed
        onChange(item, true)
    }
    /// Updates the public squeeze target continuously while the sheet handle is dragged.
    public func dragComments(to height: CGFloat) { guard sheetItem != nil else { return }; sheetHeight = min(maximumSheetHeight, max(1, height)) }
    /// Updates viewport constraints. The visible sheet and the video squeeze share this exact height.
    public func updateSheetLayout(maximumHeight: CGFloat, bottomInset: CGFloat) {
        maximumSheetHeight = max(1, maximumHeight)
        sheetBottomInset = max(0, bottomInset)
        if isSheetOpen { sheetHeight = min(sheetHeight, maximumSheetHeight); applyRestPosition() }
    }
    /// Sets the squeezed rest height for snapped sheets; nil restores continuous dragging. The kit calls this on every layout pass.
    public func updateSheetSnapping(squeezedHeight: CGFloat?) {
        squeezedSheetHeight = squeezedHeight.flatMap { $0.isFinite ? max(1, $0) : nil }
        applyRestPosition()
    }
    /// Moves an open snapped sheet to a rest position; animate at the call site. A closed sheet ignores this.
    public func snapComments(to position: SheetPosition) {
        guard isSheetOpen else { return }
        sheetPosition = position; applyRestPosition()
    }
    private func applyRestPosition() {
        guard let squeezed = squeezedSheetHeight, let position = sheetPosition else { return }
        switch position {
        case .squeezed: sheetHeight = min(maximumSheetHeight, squeezed)
        case .expanded: sheetHeight = maximumSheetHeight
        }
    }
    /// The rest position a released drag settles at, or nil when it closes. Continuous sheets return nil.
    func snapTarget(forPredictedHeight height: CGFloat) -> SheetPosition? {
        guard let squeezed = squeezedSheetHeight, height >= squeezed / 2 else { return nil }
        let expanded = maximumSheetHeight
        return expanded > squeezed && height >= (squeezed + expanded) / 2 ? .expanded : .squeezed
    }
    /// Sheet height of the squeezed rest position for a mode, or nil for continuous sheets.
    static func squeezedRestHeight(viewportHeight: CGFloat, mode: HMSocialOptions.SheetMode) -> CGFloat? {
        guard case .snapped(let fraction) = mode else { return nil }
        let video = fraction.isFinite ? min(0.9, max(0.1, fraction)) : 1.0 / 3
        return max(1, viewportHeight) * CGFloat(1 - video)
    }
    func claimPreview(for itemID: String) -> Bool { previewedItems.insert(itemID).inserted }
    /// Closes the sheet and balances its originating item callback, including cancellation.
    public func closeComments() {
        guard let item = sheetItem else { return }
        sheetHeight = 0; sheetItem = nil; sheetPosition = nil
        let callback = sheetCallback; sheetCallback = nil; callback?(item, false)
    }
    /// Whether the sheet lifetime is active, including while resizing.
    public var isSheetOpen: Bool { sheetItem != nil }
    /// Rail toggles; surface double taps add Fire. Both enter this exact animation path.
    public func fire(at point: CGPoint?, item: HMMediaItem, data: any HMSocialDataSource,
                     addOnly: Bool = false, isAdActive: Bool = false,
                     onToggle: @escaping (HMMediaItem, Bool) -> Void = { _, _ in }) {
        guard !isAdActive, !isSheetOpen, data.canFire else { return }
        let reacted = addOnly || !data.content.isReacted
        requestID += 1; fireIsPositive = reacted
        if reacted { fireTarget = fireTargets[item.id] ?? fireTarget; fireOrigin = point ?? fireTarget; fireID += 1; fireItemID = item.id }
        error = nil; errorItemID = item.id
        let event = requestID
        Task {
            do { try await data.setReacted(reacted); onToggle(item, reacted) }
            catch is CancellationError { }
            catch { if self.requestID == event { self.error = error.localizedDescription } }
        }
    }
}

/// Applies social video layout/gestures to either public playback surface. Use the same state in the overlay.
/// The overlay itself cannot set an ancestor surface's layout, so standalone composition needs this modifier.
public extension View {
    /// Applies the shared social gesture and rendering configuration to the public playback surface.
    @MainActor func hmSocialPlayback(player: HMPlayer, state: HMSocialState, options: HMSocialOptions = .init(),
                          extendsUnderSafeArea: Bool = true, data: @escaping (HMMediaItem) -> any HMSocialDataSource,
                          callbacks: HMSocialCallbacks = .init()) -> some View {
        modifier(HMSocialPlaybackModifier(player: player, state: state, options: options, extendsUnderSafeArea: extendsUnderSafeArea, data: data, callbacks: callbacks))
    }
}

/// Stable callback storage: item identity and source capability are resolved at activation, never while building hooks.
@MainActor @Observable private final class HMSocialPlaybackActions {
    @ObservationIgnored var player: HMPlayer?
    @ObservationIgnored var state: HMSocialState?
    @ObservationIgnored var data: ((HMMediaItem) -> any HMSocialDataSource)?
    @ObservationIgnored var callbacks = HMSocialCallbacks()
    private(set) var canFire = true
    @ObservationIgnored var closesSheetOnTap = false
    @ObservationIgnored var sheetAnimation: Animation?
    @ObservationIgnored var resumesAfterExpandedSheet = false
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var generation = 0
    func start() { observing = true; generation += 1; observeCapabilities(generation: generation) }
    func stop() { observing = false; generation += 1 }
    private func observeCapabilities(generation expected: Int) {
        guard observing, generation == expected else { return }
        let available = withObservationTracking {
            guard let item = player?.currentItem, let source = data?(item) else { return false }
            return source.canFire
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeCapabilities(generation: expected) }
        }
        if canFire != available { canFire = available }
    }
    @ObservationIgnored lazy var tap: () -> Void = { [weak self] in
        guard let self else { return }
        if let state = self.state, state.isSheetOpen {
            // The sheet is reserved from video taps, so this is a tap on the squeezed video itself.
            guard self.closesSheetOnTap else { return }
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            withAnimation(self.sheetAnimation) { state.closeComments() }
            return
        }
        self.player?.togglePlayPause()
    }
    @ObservationIgnored lazy var fire: (CGPoint) -> Void = { [weak self] point in
        guard let self, let player = self.player, let state = self.state,
              !player.isFullscreen, let item = player.currentItem, let data = self.data?(item) else { return }
        state.fire(at: point, item: item, data: data, addOnly: true,
                   isAdActive: player.adState.isActive, onToggle: self.callbacks.fireToggled)
    }
}

private struct HMSocialPlaybackModifier: ViewModifier {
    let player: HMPlayer
    let state: HMSocialState
    let options: HMSocialOptions
    let extendsUnderSafeArea: Bool
    let data: (HMMediaItem) -> any HMSocialDataSource
    let callbacks: HMSocialCallbacks
    @State private var actions = HMSocialPlaybackActions()
    @State private var keyboardTop: CGFloat?
    @Environment(\.hmTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        actions.player = player; actions.state = state; actions.data = data; actions.callbacks = callbacks
        actions.closesSheetOnTap = options.closesSheetOnVideoTap
        actions.sheetAnimation = reduceMotion ? nil : .easeInOut(duration: theme.sheetAnimationDuration)
        return GeometryReader { geometry in
            let safe = extendsUnderSafeArea ? geometry.safeAreaInsets : EdgeInsets()
            let bottom = max(0, options.hostNavigationHeight) + safe.bottom
            let fullHeight = geometry.size.height + safe.top + safe.bottom
            let keyboard = keyboardTop.map { max(0, geometry.frame(in: .global).maxY + safe.bottom - $0) } ?? 0
            let sheetBottom = max(bottom, keyboard)
            // Snapped rest heights follow host navigation, not the keyboard, so the squeezed video holds its size.
            let squeezed = HMSocialState.squeezedRestHeight(viewportHeight: fullHeight - bottom, mode: options.sheetMode)
            // An expanded snapped sheet reaches the top safe area; continuous sheets keep a handle gap.
            let maximum = max(1, fullHeight - safe.top - sheetBottom - (squeezed == nil ? 24 : 0))
            let height = max(0, fullHeight - max(bottom, state.sheetBottomInset) - state.sheetHeight)
            content
                .hmVideoLayout(HMVideoLayout(contentInsets: HMVideoInsets(bottom: bottom),
                    squeezeTarget: state.isSheetOpen ? CGRect(x: 0, y: 0, width: geometry.size.width, height: height) : nil))
                .hmFullscreenVideoLayout(HMVideoLayout())
                .hmFeedPagingDisabled(!options.allowsPagingWhileSheetOpen && state.isSheetOpen)
                .hmVideoGestures(isAdPlaying: player.adState.isActive,
                    onTap: actions.tap, onDoubleTap: !player.isFullscreen && !state.isSheetOpen && actions.canFire ? actions.fire : nil)
                .onChange(of: maximum, initial: true) { _, value in
                    state.updateSheetLayout(maximumHeight: value, bottomInset: sheetBottom)
                }
                .onChange(of: sheetBottom) { _, value in
                    state.updateSheetLayout(maximumHeight: maximum, bottomInset: value)
                }
                .onChange(of: squeezed, initial: true) { _, value in
                    state.updateSheetSnapping(squeezedHeight: value)
                }
        }
        .ignoresSafeArea(.keyboard)
        .onAppear { actions.start() }
        // Pause and resume go through the player; the expanded sheet never stores a position itself.
        .onChange(of: state.sheetPosition == .expanded) { _, expanded in
            if expanded {
                guard player.snapshot.state != .paused else { return }
                actions.resumesAfterExpandedSheet = true; player.pause()
            } else if actions.resumesAfterExpandedSheet {
                actions.resumesAfterExpandedSheet = false
                if player.isFeedVisible { player.play() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            keyboardTop = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.minY
        }
        .onChange(of: player.currentItem?.id) { _, _ in state.closeComments() }
        .onChange(of: player.adState.isActive) { _, active in if active { state.closeComments() } }
        .onChange(of: player.isFullscreen) { _, _ in state.closeComments() }
        .onDisappear { actions.stop(); state.closeComments() }
    }
}
#endif
