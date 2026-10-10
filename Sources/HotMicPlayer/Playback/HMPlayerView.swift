#if canImport(UIKit) && !os(watchOS)
import AVFoundation
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

    /// Creates an inline surface and partner overlay, with 16:9 default layout. Access on the main actor.
    public init(player: HMPlayer, aspectRatio: CGFloat? = 16 / 9,
                @ViewBuilder overlay: @escaping (HMMediaItem, HMPlaybackSnapshot) -> Overlay) {
        self.player = player; self.aspectRatio = aspectRatio; self.overlay = overlay
    }

    /// Renders the active item without feed paging. Access on the main actor.
    public var body: some View {
        ZStack {
            Color.black
            if let item = player.currentItem {
                HMItemSurface(player: player, item: item, fullscreen: false, observesWarmFrame: false, gravity: nil, overlay: overlay)
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipped()
        .background(HMFullscreenPresenter(player: player).frame(width: 0, height: 0))
        .task { await player.start() }
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
    /// Creates a default 16:9 UIKit surface. Pass nil to fill arbitrary parent constraints. Access on the main actor.
    public init(player: HMPlayer, aspectRatio: CGFloat? = 16 / 9) {
        self.player = player
        super.init(rootView: HMPlayerView(player: player, aspectRatio: aspectRatio))
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

    var body: some View {
        GeometryReader { geometry in
            let display = player.displayItem(item)
            let aspect = player.snapshot(for: item).aspectRatio
            let configuration = player.configuration
            let policy = item.presentation ?? configuration.presentation
            let resolved = policy.resolved(aspectRatio: aspect, container: geometry.size, tolerance: configuration.aspectRatioTolerance)
            let effectiveGravity = gravity ?? (resolved == .fill ? .resizeAspectFill : .resizeAspect)
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let videoFrame = effectiveGravity != .resizeAspect ? bounds : HMVideoPresentation.fit.videoFrame(aspectRatio: aspect, in: bounds)
            let color = resolved == .fitWithColor ? configuration.backdropColor : .black
            ZStack {
                Color(red: component(color.red), green: component(color.green), blue: component(color.blue), opacity: component(color.alpha))
                if resolved == .fitWithBlurredBackdrop {
                    if let poster = display.posterURL {
                        HMPosterView(url: poster).blur(radius: 24).overlay(Color.black.opacity(0.5))
                    } else if let poster = player.node(for: item)?.backdropPoster {
                        Color.clear.overlay {
                            Image(decorative: poster, scale: 1).resizable().scaledToFill()
                        }.clipped().blur(radius: 24).overlay(Color.black.opacity(0.5))
                    }
                }
                if let poster = display.posterURL {
                    HMPosterView(url: poster)
                        .frame(width: videoFrame.width, height: videoFrame.height)
                }
                HMVideoSurface(node: player.isFullscreen == fullscreen ? player.node(for: item) : nil,
                               gravity: effectiveGravity, observesWarmFrame: observesWarmFrame,
                               capturesBackdrop: resolved == .fitWithBlurredBackdrop && display.posterURL == nil)
                overlay(display, overlaySnapshot(videoFrame))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }
    private func overlaySnapshot(_ frame: CGRect) -> HMPlaybackSnapshot {
        var snapshot = player.snapshot(for: item); snapshot.videoFrame = frame; return snapshot
    }
    private func component(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
}

/// A zero-size child controller presents fullscreen from the host's actual window scene.
struct HMFullscreenPresenter: UIViewControllerRepresentable {
    let player: HMPlayer
    func makeUIViewController(context: Context) -> HMFullscreenPresenterController { HMFullscreenPresenterController(player: player) }
    func updateUIViewController(_ controller: HMFullscreenPresenterController, context: Context) {
        controller.synchronize(fullscreen: player.isFullscreen, itemID: player.currentItem?.id)
    }
    static func dismantleUIViewController(_ controller: HMFullscreenPresenterController, coordinator: ()) { controller.stop() }
}

final class HMFullscreenPresenterController: UIViewController {
    let player: HMPlayer
    private var fullscreenController: UIViewController?
    private var rotationToken: NSObjectProtocol?
    private var rotationTask: Task<Void, Never>?
    private var transitioning = false
    private var stopped = false
    private weak var windowScene: UIWindowScene?
    #if os(iOS)
    private var previousOrientation: UIInterfaceOrientation = .portrait
    #endif
    init(player: HMPlayer) {
        self.player = player
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
                // UIKit rotates the host independently of device notifications. Presenting
                // during that turn can leave an overFullScreen controller in portrait bounds.
                let sceneMatches = self.view.window?.windowScene?.interfaceOrientation.isLandscape == orientation.isLandscape
                let coordinator = self.fullscreenController?.transitionCoordinator ?? self.transitionCoordinator ?? self.view.window?.rootViewController?.transitionCoordinator
                settledChecks = sceneMatches && coordinator == nil ? settledChecks + 1 : 0
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
        if fullscreen, fullscreenController == nil, view.window != nil {
            let controller = HMFullscreenController(rootView: HMFullscreenContent(player: player))
            controller.modalPresentationStyle = .overFullScreen
            windowScene = view.window?.windowScene
            #if os(iOS)
            // UIHostingController otherwise prefers portrait on presentation, even when
            // the host has just rotated to landscape. Avoid a portrait/landscape round trip.
            controller.presentationOrientation = windowScene?.interfaceOrientation ?? .portrait
            if (player.snapshot.aspectRatio ?? 0) > 1 {
                controller.presentationOrientation = UIDevice.current.orientation == .landscapeRight ? .landscapeLeft : .landscapeRight
            }
            #endif
            fullscreenController = controller; transitioning = true
            #if os(iOS)
            previousOrientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
            #endif
            present(controller, animated: false) { [weak self] in
                guard let self else { return }
                self.transitioning = false
                #if os(iOS)
                if (self.player.snapshot.aspectRatio ?? 0) > 1 { self.requestOrientation(.landscape) }
                #endif
                self.synchronize(fullscreen: self.player.isFullscreen, itemID: self.player.currentItem?.id)
            }
        } else if !fullscreen, let controller = fullscreenController {
            transitioning = true
            controller.dismiss(animated: false) { [weak self] in
                guard let self else { return }
                self.fullscreenController = nil; self.transitioning = false
                #if os(iOS)
                self.requestOrientation(UIDevice.current.orientation.isPortrait ? .portrait : UIInterfaceOrientationMask(rawValue: 1 << self.previousOrientation.rawValue))
                #endif
                self.synchronize(fullscreen: self.player.isFullscreen, itemID: self.player.currentItem?.id)
            }
        }
    }
    #if os(iOS)
    private func requestOrientation(_ orientations: UIInterfaceOrientationMask) {
        (fullscreenController?.view.window?.windowScene ?? view.window?.windowScene ?? windowScene)?.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { _ in }
    }
    #endif
    func stop() {
        guard !stopped else { return }
        stopped = true
        rotationTask?.cancel(); rotationTask = nil
        if let rotationToken { NotificationCenter.default.removeObserver(rotationToken); self.rotationToken = nil }
        #if os(iOS)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        #endif
        fullscreenController?.dismiss(animated: false); fullscreenController = nil
        player.exitFullscreen()
    }
}

private final class HMFullscreenController: UIHostingController<HMFullscreenContent> {
    #if os(iOS)
    var presentationOrientation: UIInterfaceOrientation = .portrait
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { presentationOrientation }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var prefersStatusBarHidden: Bool { true }
    #endif
}

private struct HMFullscreenContent: View {
    let player: HMPlayer
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let item = player.currentItem {
                HMItemSurface(player: player, item: item, fullscreen: true, observesWarmFrame: false, gravity: nil) { _, _ in EmptyView() }
                    .ignoresSafeArea()
            }
            Button { player.exitFullscreen() } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left").padding(16).background(.black.opacity(0.6), in: Circle())
            }
            .accessibilityIdentifier("hm-exit-fullscreen")
            .padding().tint(.white)
        }
    }
}
#endif
