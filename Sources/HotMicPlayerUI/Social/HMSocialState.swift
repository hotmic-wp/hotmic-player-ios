#if os(iOS)
import SwiftUI
import Observation
import HotMicPlayer

/// Shared between HMSocialOverlay and hmSocialPlayback. One Fire event drives both burst and rail.
@MainActor @Observable public final class HMSocialState {
    /// Preferred sheet height in points, clamped to the available viewport.
    public private(set) var sheetHeight: CGFloat = 0
    /// Monotonically increasing event shared by burst and rail.
    public private(set) var fireID = 0
    /// Latest surface tap location, or the rail target for a rail activation.
    public private(set) var fireOrigin: CGPoint?
    /// Center of the current rail icon in surface coordinates.
    public var fireTarget: CGPoint = .zero
    /// Latest Fire action failure, suitable for displaying to the viewer.
    public private(set) var error: String?
    var fireItemID: String?
    var errorItemID: String?
    private var sheetItem: HMMediaItem?
    @ObservationIgnored private var sheetCallback: ((HMMediaItem, Bool) -> Void)?
    /// Creates this component with host-supplied data and actions.
    public init() {}
    /// Opens the default or replacement sheet unless an ad or another sheet is active.
    public func openComments(item: HMMediaItem, height: CGFloat, isAdActive: Bool,
                             onChange: @escaping (HMMediaItem, Bool) -> Void = { _, _ in }) {
        guard !isAdActive, sheetItem == nil else { return }
        sheetItem = item; sheetCallback = onChange; sheetHeight = max(0, height)
        onChange(item, true)
    }
    /// Updates the public squeeze target continuously while the sheet handle is dragged.
    public func dragComments(to height: CGFloat) { guard sheetItem != nil else { return }; sheetHeight = max(1, height) }
    /// Closes the sheet and balances its originating item callback, including cancellation.
    public func closeComments() {
        guard let item = sheetItem else { return }
        sheetHeight = 0; sheetItem = nil
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
        fireOrigin = point ?? fireTarget; fireID += 1; fireItemID = item.id; error = nil; errorItemID = item.id
        let event = fireID
        Task {
            do { try await data.setReacted(reacted); onToggle(item, reacted) }
            catch is CancellationError { }
            catch { if self.fireID == event { self.error = error.localizedDescription } }
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

private struct HMSocialPlaybackModifier: ViewModifier {
    let player: HMPlayer
    let state: HMSocialState
    let options: HMSocialOptions
    let extendsUnderSafeArea: Bool
    let data: (HMMediaItem) -> any HMSocialDataSource
    let callbacks: HMSocialCallbacks
    private var fireHandler: ((CGPoint) -> Void)? {
        guard !player.isFullscreen, !state.isSheetOpen, let item = player.currentItem, data(item).canFire else { return nil }
        return { point in
            guard let current = player.currentItem else { return }
            state.fire(at: point, item: current, data: data(current), addOnly: true,
                       isAdActive: player.adState.isActive, onToggle: callbacks.fireToggled)
        }
    }
    func body(content: Content) -> some View {
        GeometryReader { geometry in
            let bottom = options.hostNavigationHeight + (extendsUnderSafeArea ? geometry.safeAreaInsets.bottom : 0)
            let height = max(0, geometry.size.height + (extendsUnderSafeArea ? geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom : 0) - bottom - state.sheetHeight)
            content
                .hmVideoLayout(HMVideoLayout(contentInsets: HMVideoInsets(bottom: bottom),
                    squeezeTarget: state.isSheetOpen ? CGRect(x: 0, y: 0, width: geometry.size.width, height: height) : nil))
                .hmFullscreenVideoLayout(HMVideoLayout())
                .hmVideoGestures(isAdPlaying: player.adState.isActive,
                    onTap: { guard !state.isSheetOpen else { return }; player.togglePlayPause() },
                    onDoubleTap: fireHandler)

        }
        .onChange(of: player.currentItem?.id) { _, _ in state.closeComments() }
        .onChange(of: player.adState.isActive) { _, active in if active { state.closeComments() } }
        .onChange(of: player.isFullscreen) { _, _ in state.closeComments() }
        .onDisappear { state.closeComments() }
    }
}
#endif
