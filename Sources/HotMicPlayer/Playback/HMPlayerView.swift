#if canImport(UIKit) && !os(watchOS)
import AVFoundation
import CoreImage
import SwiftUI
import Observation
import UIKit

/// A non-paging inline player. Set the playlist on HMPlayer and use its next/previous controls.
/// The default layout is 16:9; supply aspectRatio: nil to fill a host-chosen frame.
@MainActor
public struct HMPlayerView<Overlay: View>: View {
    private let player: HMPlayer
    private let aspectRatio: CGFloat?
    private let overlay: (HMMediaItem, HMPlaybackSnapshot) -> Overlay
    var surfaceHooks: HMSurfaceHooks?
    var extendsUnderSafeArea = false
    private var fullscreenOverlay: ((HMMediaItem, HMPlaybackSnapshot) -> AnyView)?

    /// Creates an inline surface and partner overlay, with 16:9 default layout. Access on the main actor.
    public init(player: HMPlayer, aspectRatio: CGFloat? = 16 / 9,
                @ViewBuilder overlay: @escaping (HMMediaItem, HMPlaybackSnapshot) -> Overlay) {
        self.player = player; self.aspectRatio = aspectRatio; self.overlay = overlay
    }

    init(player: HMPlayer, aspectRatio: CGFloat?, fullscreenOverlay: @escaping (HMMediaItem, HMPlaybackSnapshot) -> AnyView, overlay: @escaping (HMMediaItem, HMPlaybackSnapshot) -> Overlay) {
        self.player = player; self.aspectRatio = aspectRatio
        self.overlay = overlay; self.fullscreenOverlay = fullscreenOverlay
    }

    /// Renders the active item without feed paging. Access on the main actor.
    public var body: some View {
        surfaceBody.transformEnvironment(\.hmSurfaceHooks) { hooks in
            if let surfaceHooks { hooks = surfaceHooks }
        }
        .ignoresSafeArea(.container, edges: extendsUnderSafeArea ? .all : [])
    }
    private var surfaceBody: some View {
        ZStack {
            Color.black
            if let item = player.currentItem {
                HMItemSurface(player: player, item: item, fullscreen: false, observesWarmFrame: false, gravity: nil, overlay: overlay)
            }
        }
        .modifier(HMInlineAspectRatio(ratio: aspectRatio))
        .clipped()
        .background(HMFullscreenPresenter(player: player, overlay: fullscreenOverlay ?? { AnyView(overlay($0, $1)) }).frame(width: 0, height: 0))
        .onAppear { player.attachInline() }
        .onDisappear { player.detachInline() }
        .task { await player.start() }
    }
}

/// SwiftUI's aspectRatio(nil) infers the content's ideal ratio; nil in our API means no constraint.
private struct HMInlineAspectRatio: ViewModifier {
    let ratio: CGFloat?
    @ViewBuilder func body(content: Content) -> some View {
        if let ratio { content.aspectRatio(ratio, contentMode: .fit) }
        else { content }
    }
}

public extension HMPlayerView where Overlay == EmptyView {
    /// Creates an inline player without an overlay. Access on the main actor.
    init(player: HMPlayer, aspectRatio: CGFloat? = 16 / 9) {
        self.init(player: player, aspectRatio: aspectRatio) { _, _ in EmptyView() }
    }
}

/// UIKit inline equivalent. Embed as a child view controller and constrain its view (typically 16:9).
/// Owns no separate engine; mute, loops, seek, next/previous and fullscreen belong to `player`.
@MainActor
public final class HMPlayerViewController: UIHostingController<HMPlayerView<EmptyView>> {
    /// Shared playback engine controlled by the host. Access on the main actor.
    public let player: HMPlayer
    private var surfaceAspectRatio: CGFloat? = 16 / 9
    private var surfaceFullscreenOverlay: ((HMMediaItem, HMPlaybackSnapshot) -> AnyView)?
    /// Rendering-only content insets and squeeze viewport, in view coordinates.
    public var videoLayout = HMVideoLayout() { didSet { updateSurface() } }
    /// Fullscreen has zero insets and no squeeze by default; supply an independent layout if needed.
    public var fullscreenVideoLayout: HMVideoLayout? { didSet { updateSurface() } }
    /// Opt in to drawing underneath the controller's safe area. Default is false.
    public var extendsUnderSafeArea = false { didSet { updateSurface() } }
    /// Called after layout when the visible video frame changes, in controller coordinates.
    public var onVideoFrameChange: ((CGRect) -> Void)?
    private var reportedVideoFrame: CGRect?
    /// Resulting visible video bounds after layout, in this controller's view coordinates, excluding fit bars.
    public var videoFrame: CGRect {
        guard isViewLoaded else { return .zero }
        func surface(in view: UIView) -> HMVideoGestureView? {
            if let view = view as? HMVideoGestureView { return view }
            return view.subviews.lazy.compactMap { surface(in: $0) }.first
        }
        guard let surface = surface(in: view) else { return .zero }
        return surface.convert(surface.videoFrame, to: view)
    }
    /// Sibling UIKit overlay rectangles, converted into this view's coordinates by the host.
    public var excludedHitAreas: [CGRect] = [] { didSet { updateSurface() } }
    /// Additional caption-safe surface-edge insets; registered excludedHitAreas are also reserved.
    public var captionInsets = HMVideoInsets.zero { didSet { updateSurface() } }
    /// Suppresses taps and video accessibility actions during ads.
    public var isAdPlaying = false { didSet { updateSurface() } }
    /// Overrides the default single-tap toggle.
    public var onTap: (() -> Void)? { didSet { updateSurface() } }
    /// Fire callback in view coordinates; also exposed as a VoiceOver custom action.
    public var onDoubleTap: ((CGPoint) -> Void)? { didSet { updateSurface() } }
    /// Accessible name of the video element; defaults to the localized word Video.
    public var videoAccessibilityLabel = HMVideoAccessibility.text("Video") { didSet { updateSurface() } }
    private func updateSurface() {
        var surface = HMPlayerView(player: player, aspectRatio: surfaceAspectRatio,
                                   fullscreenOverlay: surfaceFullscreenOverlay ?? { _, _ in AnyView(EmptyView()) },
                                   overlay: { _, _ in EmptyView() })
        surface.extendsUnderSafeArea = extendsUnderSafeArea
        surface.surfaceHooks = HMSurfaceHooks(layout: videoLayout, fullscreenLayout: fullscreenVideoLayout, excludedRegions: excludedHitAreas,
            isAdPlaying: isAdPlaying, accessibilityLabel: videoAccessibilityLabel, onTap: onTap, onDoubleTap: onDoubleTap,
            onFrameChange: { [weak self] surface in
                guard let self, self.isViewLoaded else { return }
                let frame = surface.convert(surface.videoFrame, to: self.view)
                self.reportVideoFrame(frame)
            }, coordinateReference: { [weak self] in self?.viewIfLoaded })
        surface.surfaceHooks?.captionInsets = captionInsets
        rootView = surface
    }
    private func reportVideoFrame(_ frame: CGRect) {
        guard frame != reportedVideoFrame else { return }
        reportedVideoFrame = frame; onVideoFrameChange?(frame)
    }
    /// Reports changed video bounds after UIKit lays out the hosting view. Access on the main actor.
    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews(); reportVideoFrame(videoFrame)
    }
    /// Creates a default 16:9 UIKit surface. Pass nil to fill arbitrary parent constraints. Access on the main actor.
    public init(player: HMPlayer, aspectRatio: CGFloat? = 16 / 9) {
        self.player = player
        self.surfaceAspectRatio = aspectRatio
        var surface = HMPlayerView(player: player, aspectRatio: aspectRatio)
        surface.surfaceHooks = HMSurfaceHooks()
        super.init(rootView: surface)
        updateSurface()
    }
    /// Creates a UIKit surface with captions or controls rendered in fullscreen. Access on the main actor.
    public init<Content: View>(player: HMPlayer, aspectRatio: CGFloat? = 16 / 9,
                              @ViewBuilder fullscreenOverlay: @escaping (HMMediaItem, HMPlaybackSnapshot) -> Content) {
        self.player = player
        self.surfaceAspectRatio = aspectRatio
        self.surfaceFullscreenOverlay = { AnyView(fullscreenOverlay($0, $1)) }
        var surface = HMPlayerView(player: player, aspectRatio: aspectRatio,
            fullscreenOverlay: { AnyView(fullscreenOverlay($0, $1)) }, overlay: { _, _ in EmptyView() })
        surface.surfaceHooks = HMSurfaceHooks()
        super.init(rootView: surface)
        updateSurface()
    }
    @available(*, unavailable)
    required dynamic init?(coder aDecoder: NSCoder) { fatalError("Use init(player:)") }
}

/// Shared rendering path for feed, inline, and fullscreen. The only native video layer travels with the node.
struct HMItemSurface<Overlay: View>: View {
    let player: HMPlayer
    let item: HMMediaItem
    let fullscreen: Bool
    let observesWarmFrame: Bool
    let gravity: AVLayerVideoGravity?
    let overlay: (HMMediaItem, HMPlaybackSnapshot) -> Overlay
    @Environment(\.hmSurfaceHooks) private var hooks
    @Environment(\.hmFeedSafeArea) private var feedSafeArea
    @Environment(\.hmCompanionBand) private var companionBand
    @State private var hitSpace = UUID()
    @State private var overlayRegions: [CGRect] = []

    var body: some View {
        GeometryReader { geometry in
            let display = player.displayItem(item)
            let aspect = player.snapshot(for: item).aspectRatio
            let configuration = player.configuration
            let policy = item.presentation ?? configuration.presentation
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let viewport = hooks.layout.viewport(in: bounds)
            // Resolve policy before squeeze so a drag cannot flip automatic fill/fit mid-flight.
            let policySize = HMVideoLayout(contentInsets: hooks.layout.contentInsets).viewport(in: bounds).size
            let resolved = policy.resolved(aspectRatio: aspect, container: policySize, tolerance: configuration.aspectRatioTolerance)
            let effectiveGravity = gravity ?? (resolved == .fill ? .resizeAspectFill : .resizeAspect)
            let videoFrame = effectiveGravity != .resizeAspect ? viewport : HMVideoPresentation.fit.videoFrame(aspectRatio: aspect, in: viewport)
            // The companion band is reserved like a host region, so captions and sidecars avoid it.
            let regions = hooks.excludedRegions + overlayRegions + (companionBand.map { [$0] } ?? [])
            let color = resolved == .fitWithColor ? configuration.backdropColor : .black
            ZStack {
                Color(red: component(color.red), green: component(color.green), blue: component(color.blue), opacity: component(color.alpha))
                if resolved == .fitWithBlurredBackdrop {
                    if let poster = display.posterURL {
                        HMBlurredPosterView(url: poster).overlay(Color.black.opacity(0.5))
                    } else if let poster = player.node(for: item)?.backdropPoster {
                        Color.clear.overlay {
                            Image(decorative: poster, scale: 1).resizable().scaledToFill()
                        }.clipped().overlay(Color.black.opacity(0.5))
                    }
                }
                if let poster = display.posterURL {
                    HMPosterView(url: poster)
                        .frame(width: videoFrame.width, height: videoFrame.height)
                        .position(x: videoFrame.midX, y: videoFrame.midY)
                }
                HMVideoSurface(node: player.isFullscreen == fullscreen ? player.node(for: item) : nil,
                               gravity: effectiveGravity,
                               // Keep the incoming decoded frame's display proof while decisioning
                               // holds content inactive. No fill must not cost two fresh boundaries.
                               observesWarmFrame: observesWarmFrame || (player.currentItem?.id == item.id && player.adState == .loading),
                               capturesBackdrop: resolved == .fitWithBlurredBackdrop && display.posterURL == nil)
                    .frame(width: viewport.width, height: viewport.height)
                    .position(x: viewport.midX, y: viewport.midY)
                    .allowsHitTesting(false)
                HMVideoGestureSurface(hooks: hooks, videoFrame: videoFrame, viewport: viewport, regions: regions,
                                      state: player.snapshot(for: item).state,
                                      wantsPlayback: player.wantsPlayback,
                                      enabled: !player.adState.isActive && player.currentItem?.id == item.id && player.isFullscreen == fullscreen,
                                      toggle: { player.togglePlayPause() }, title: display.title,
                                      snapshot: player.snapshot(for: item), muted: player.isMuted,
                                      captions: player.captionsEnabled, hasCaptions: !player.availableCaptionLanguages.isEmpty,
                                      toggleMute: { player.toggleMute() }, toggleCaptions: { player.captionsEnabled.toggle() },
                                      seek: { player.seek(to: $0) })
                    .frame(width: geometry.size.width, height: geometry.size.height)
                if player.currentItem?.id == item.id, player.adState.isActive, player.isFullscreen == fullscreen {
                    HMAdSurface(player: player).frame(width: geometry.size.width, height: geometry.size.height)
                }
                if player.currentItem?.id == item.id, !player.adState.isActive, player.isFullscreen == fullscreen,
                   let node = player.node(for: item) {
                    let safe = HMVideoInsets(top: max(geometry.safeAreaInsets.top, feedSafeArea.top), left: max(geometry.safeAreaInsets.leading, feedSafeArea.leading),
                                             bottom: max(geometry.safeAreaInsets.bottom, feedSafeArea.bottom), right: max(geometry.safeAreaInsets.trailing, feedSafeArea.trailing))
                    HMCaptionOverlay(controller: node.captions, text: node.captions.text(at: node.snapshot.currentTime),
                        videoFrame: videoFrame, safeArea: safe, insets: hooks.captionInsets, regions: regions,
                        coordinateReference: hooks.coordinateReference, hostRegions: hooks.excludedRegions,
                        useNative: item.captionSources.isEmpty && regions.isEmpty && hooks.captionInsets == .zero && safe == .zero,
                        styleRevision: player.captionStyleRevision)
                        .allowsHitTesting(false)
                }
                overlay(display, overlaySnapshot(videoFrame))
                    .environment(\.hmHitSpace, hitSpace)
                    .environment(\.hmReservedRegions, regions)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .coordinateSpace(name: hitSpace)
            .onPreferenceChange(HMHitAreaPreference.self) { if overlayRegions != $0 { overlayRegions = $0 } }
            .clipped()
        }
    }
    private func overlaySnapshot(_ frame: CGRect) -> HMPlaybackSnapshot {
        var snapshot = player.snapshot(for: item); snapshot.videoFrame = frame; snapshot.companionFrame = companionBand; return snapshot
    }
    private func component(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
}

/// A zero-size child controller presents fullscreen from the host's actual window scene.
struct HMFullscreenPresenter: UIViewControllerRepresentable {
    @Environment(\.hmSurfaceHooks) private var hooks
    let player: HMPlayer
    var overlay: (HMMediaItem, HMPlaybackSnapshot) -> AnyView = { _, _ in AnyView(EmptyView()) }
    func makeUIViewController(context: Context) -> HMFullscreenPresenterController { HMFullscreenPresenterController(player: player, overlay: overlay, hooks: hooks) }
    func updateUIViewController(_ controller: HMFullscreenPresenterController, context: Context) {
        controller.overlay = overlay
        controller.hooks = hooks
        controller.updateHooks()
        // Fullscreen/item observation and viewDidAppear synchronize presentation independently.
    }
    static func dismantleUIViewController(_ controller: HMFullscreenPresenterController, coordinator: ()) { controller.stop() }
}

final class HMFullscreenPresenterController: UIViewController {
    let player: HMPlayer
    private(set) var fullscreenController: UIViewController?
    var hooks: HMSurfaceHooks
    func updateHooks() {
        if let controller = fullscreenController as? HMFullscreenController {
            controller.rootView = HMFullscreenContent(player: player, overlay: overlay, hooks: hooks)
        }
    }
    var overlay: (HMMediaItem, HMPlaybackSnapshot) -> AnyView
    private var presentationCheck: Task<Void, Never>?
    private var rotationToken: NSObjectProtocol?
    private var rotationTask: Task<Void, Never>?
    private(set) var transitioning = false
    private var stopped = false
    private weak var windowScene: UIWindowScene?
    #if os(iOS)
    private var previousOrientation: UIInterfaceOrientation = .portrait
    #endif
    init(player: HMPlayer, overlay: @escaping (HMMediaItem, HMPlaybackSnapshot) -> AnyView = { _, _ in AnyView(EmptyView()) }, hooks: HMSurfaceHooks = HMSurfaceHooks()) {
        self.player = player; self.overlay = overlay; self.hooks = hooks
        super.init(nibName: nil, bundle: nil)
        #if os(iOS)
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        rotationToken = NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.followDeviceRotation()
            }
        }
        #endif
    }
    #if os(iOS)
    private func followDeviceRotation() {
        rotationTask?.cancel()
        guard player.configuration.followsDeviceRotation else { return }
        rotationTask = Task { @MainActor [weak self] in
            var settledChecks = 0
            for _ in 0..<40 {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard let self, !self.stopped else { return }
                let orientation = UIDevice.current.orientation
                guard orientation.isLandscape || orientation.isPortrait else { return }
                // Wait for any host transition, but do not require the feed scene to
                // rotate: a portrait feed can present an independently rotating fullscreen.
                let coordinator = self.fullscreenController?.transitionCoordinator ?? self.transitionCoordinator ?? self.view.window?.rootViewController?.transitionCoordinator
                settledChecks = coordinator == nil ? settledChecks + 1 : 0
                if settledChecks >= 2 {
                    self.player.deviceRotated(isLandscape: orientation.isLandscape)
                    return
                }
            }
        }
    }
    #endif
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        observeFullscreen()
    }
    // Observe independently of SwiftUI so exit also works while a host suspends inline updates.
    // overFullScreen keeps the inline hierarchy mounted, preserving its scroll and render state.
    private func observeFullscreen() {
        guard !stopped else { return }
        withObservationTracking {
            _ = player.isFullscreen; _ = player.currentItem?.id
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.synchronize(fullscreen: self.player.isFullscreen, itemID: self.player.currentItem?.id)
                self.observeFullscreen()
            }
        }
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); synchronize(fullscreen: player.isFullscreen, itemID: player.currentItem?.id) }
    func synchronize(fullscreen: Bool, itemID: String?) {
        guard !stopped, !transitioning else { return }
        if fullscreen, itemID == nil { player.exitFullscreen(); return }
        if fullscreen, fullscreenController == nil, let window = view.window {
            // Duplicate mounted surfaces must neither compete nor dismiss the owner's controller.
            guard player.fullscreenPresenter == nil || player.fullscreenPresenter === self else { return }
            player.fullscreenPresenter = self
            var presenter = window.rootViewController ?? self
            while let presented = presenter.presentedViewController { presenter = presented }
            guard presenter.presentedViewController == nil, !presenter.isBeingDismissed,
                  !presenter.isBeingPresented, presenter.view.window != nil,
                  presenter.transitionCoordinator == nil else { presentationFailed(); return }
            let controller = HMFullscreenController(rootView: HMFullscreenContent(player: player, overlay: overlay, hooks: hooks))
            controller.modalPresentationStyle = .overFullScreen
            windowScene = window.windowScene
            #if os(iOS)
            let current = windowScene?.interfaceOrientation ?? .portrait
            previousOrientation = current
            let supported = UIApplication.shared.supportedInterfaceOrientations(for: window)
            controller.orientationMask = supported
            controller.presentationOrientation = Self.presentationOrientation(current: current,
                device: UIDevice.current.orientation, landscapeItem: (player.snapshot.aspectRatio ?? 0) > 1, supported: supported)
            #endif
            fullscreenController = controller; transitioning = true
            presenter.present(controller, animated: false) { [weak self, weak controller] in
                guard let self, let controller, self.fullscreenController === controller else { return }
                guard controller.presentingViewController != nil else { self.presentationFailed(); return }
                self.presentationCheck?.cancel(); self.presentationCheck = nil
                self.transitioning = false
                #if os(iOS)
                if (self.player.snapshot.aspectRatio ?? 0) > 1 { self.requestOrientation(.landscape) }
                #endif
                self.synchronize(fullscreen: self.player.isFullscreen, itemID: self.player.currentItem?.id)
            }
            // UIKit does not call completion when it refuses a presentation.
            presentationCheck = Task { @MainActor [weak self, weak controller] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, let controller, self.fullscreenController === controller else { return }
                if controller.presentingViewController == nil || controller.view.window == nil { self.presentationFailed() }
            }
        } else if !fullscreen, let controller = fullscreenController {
            transitioning = true
            controller.dismiss(animated: false) { [weak self] in
                guard let self else { return }
                self.fullscreenController = nil; self.transitioning = false
                #if os(iOS)
                self.requestOrientation(UIDevice.current.orientation.isPortrait ? .portrait : UIInterfaceOrientationMask(rawValue: 1 << self.previousOrientation.rawValue))
                #endif
                if self.player.fullscreenPresenter === self { self.player.fullscreenPresenter = nil }
                self.synchronize(fullscreen: self.player.isFullscreen, itemID: self.player.currentItem?.id)
            }
        }
    }
    private func presentationFailed() {
        presentationCheck?.cancel(); presentationCheck = nil
        fullscreenController?.dismiss(animated: false)
        fullscreenController = nil; transitioning = false
        if player.fullscreenPresenter === self {
            player.fullscreenPresenter = nil
            player.exitFullscreen()
        }
    }
    #if os(iOS)
    static func presentationOrientation(current: UIInterfaceOrientation, device: UIDeviceOrientation,
                                        landscapeItem: Bool, supported: UIInterfaceOrientationMask) -> UIInterfaceOrientation {
        guard landscapeItem, !supported.intersection(.landscape).isEmpty else { return current }
        let desired: UIInterfaceOrientation = device == .landscapeRight ? .landscapeLeft : .landscapeRight
        return supported.contains(UIInterfaceOrientationMask(rawValue: 1 << desired.rawValue)) ? desired :
            (supported.contains(.landscapeLeft) ? .landscapeLeft : .landscapeRight)
    }
    private func requestOrientation(_ orientations: UIInterfaceOrientationMask) {
        let window = fullscreenController?.view.window ?? view.window
        let allowed = orientations.intersection(UIApplication.shared.supportedInterfaceOrientations(for: window))
        guard !allowed.isEmpty else { return }
        (window?.windowScene ?? windowScene)?.requestGeometryUpdate(.iOS(interfaceOrientations: allowed)) { _ in }
    }
    #endif
    func stop() {
        guard !stopped else { return }
        stopped = true
        rotationTask?.cancel(); rotationTask = nil
        presentationCheck?.cancel(); presentationCheck = nil
        if let rotationToken { NotificationCenter.default.removeObserver(rotationToken); self.rotationToken = nil }
        #if os(iOS)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        #endif
        fullscreenController?.dismiss(animated: false); fullscreenController = nil
        if player.fullscreenPresenter === self {
            player.fullscreenPresenter = nil
            player.exitFullscreen()
        }
    }
}

private final class HMFullscreenController: UIHostingController<HMFullscreenContent> {
    #if os(iOS)
    var presentationOrientation: UIInterfaceOrientation = .portrait
    var orientationMask: UIInterfaceOrientationMask = .allButUpsideDown
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { presentationOrientation }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { orientationMask }
    override var prefersStatusBarHidden: Bool { true }
    #endif
}

private struct HMFullscreenContent: View {
    let player: HMPlayer
    let overlay: (HMMediaItem, HMPlaybackSnapshot) -> AnyView
    var hooks = HMSurfaceHooks()
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let item = player.currentItem {
                HMItemSurface(player: player, item: item, fullscreen: true, observesWarmFrame: false, gravity: nil, overlay: overlay)
                    .environment(\.hmSurfaceHooks, hooks.forFullscreen)
                    .ignoresSafeArea()
            }
            Button { player.exitFullscreen() } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left").padding(16).background(.black.opacity(0.6), in: Circle())
            }
            .accessibilityIdentifier("hm-exit-fullscreen")
            .padding().tint(.white)
        }
        // VoiceOver's escape gesture leaves fullscreen from anywhere on the surface, whatever the overlay shows.
        .accessibilityAction(.escape) { player.exitFullscreen() }
    }
}
/// Partner posters use the same small, preblurred still path as decoded frames.
private struct HMBlurredPosterView: View {
    let url: URL
    @State private var poster: CGImage?
    var body: some View {
        Color.clear.overlay {
            if let poster { Image(decorative: poster, scale: 1).resizable().scaledToFill() }
        }.clipped().allowsHitTesting(false).task(id: url) {
            poster = nil
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
            let image = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let image = CIImage(data: data) else { return nil }
                return HMBackdropImage.make(image.oriented(forExifOrientation: image.properties[kCGImagePropertyOrientation as String] as? Int32 ?? 1))
            }.value
            if !Task.isCancelled { poster = image }
        }
    }
}
#endif
