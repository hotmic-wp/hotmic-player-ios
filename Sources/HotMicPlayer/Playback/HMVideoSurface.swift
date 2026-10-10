#if canImport(UIKit) && !os(watchOS)
import AVFoundation
import SwiftUI
import UIKit

/// Hosts a pooled node's `AVPlayerLayer`.
///
/// Deliberately *not* `AVPlayerViewController`: no transport chrome, no
/// PiP/routing machinery, no view-controller lifecycle. Just the layer, sized to
/// the cell. That is the whole "lightweight wrapper around the native player"
/// claim, and it is what keeps a feed cell cheap enough to recycle.
struct HMVideoSurface: UIViewRepresentable {

    @Environment(\.scenePhase) private var scenePhase
    private let node: HMPlayerNode?
    private let gravity: AVLayerVideoGravity
    private let active: Bool
    private let activationID: String?
    private let displayRevision: Int?
    // Explicit representable inputs wake the bounded watcher after KVO changes.
    private let frameReady: Bool
    private let isPlaying: Bool
    private let isPaused: Bool
    private let observesWarmFrame: Bool
    private let capturesBackdrop: Bool

    init(node: HMPlayerNode?, gravity: AVLayerVideoGravity = .resizeAspectFill, observesWarmFrame: Bool = false, capturesBackdrop: Bool = false) {
        self.node = node
        self.gravity = gravity
        self.active = node?.isActive ?? false
        self.activationID = node?.snapshot.activationID
        self.displayRevision = node?.displayRevision
        self.frameReady = node?.snapshot.isFrameReady ?? false
        self.isPlaying = node?.snapshot.state == .playing
        self.isPaused = node?.snapshot.state == .paused
        self.observesWarmFrame = observesWarmFrame
        self.capturesBackdrop = capturesBackdrop
    }

    func makeUIView(context: Context) -> HMVideoSurfaceView {
        let view = HMVideoSurfaceView()
        view.backgroundColor = .clear
        view.isPlaybackVisible = scenePhase == .active
        view.capturesBackdrop = capturesBackdrop
        view.observesWarmFrame = observesWarmFrame
        view.attach(node, gravity: gravity)
        return view
    }

    func updateUIView(_ uiView: HMVideoSurfaceView, context: Context) {
        uiView.isPlaybackVisible = scenePhase == .active
        uiView.capturesBackdrop = capturesBackdrop
        uiView.observesWarmFrame = observesWarmFrame
        uiView.attach(node, gravity: gravity)
    }
}

/// Plain `UIView` whose only job is to own and size one `AVPlayerLayer`.
final class HMVideoSurfaceView: UIView {

    private weak var hostedLayer: AVPlayerLayer?
    private weak var node: HMPlayerNode?
    private var displayLink: CADisplayLink?
    private var readyItem: HMMediaItem?
    private var readyRevision: Int?
    private var captureBoundaries = 0
    var isPlaybackVisible = true { didSet { refreshDisplayLink() } }
    var capturesBackdrop = false { didSet { refreshDisplayLink() } }
    var observesWarmFrame = false { didSet { refreshDisplayLink() } }

    func attach(_ node: HMPlayerNode?, gravity: AVLayerVideoGravity) {
        let layer = node?.playerLayer
        if hostedLayer !== layer {
            self.node?.discardBackdropOutput()
            // A recycled layer may already belong to another surface.
            if hostedLayer?.superlayer === self.layer { hostedLayer?.removeFromSuperlayer() }
            hostedLayer = layer; self.node = node
            layer?.removeFromSuperlayer()
            if let layer { self.layer.addSublayer(layer) }
            readyItem = nil; captureBoundaries = 0
            setNeedsLayout()
        }
        if layer?.videoGravity != gravity { layer?.videoGravity = gravity }
        if layer?.frame != bounds { setNeedsLayout() }
        refreshDisplayLink()
    }

    override var isHidden: Bool { didSet { refreshDisplayLink() } }

    private func refreshDisplayLink() {
        if !isPlaybackVisible || isHidden || node == nil || window == nil ||
            (capturesBackdrop && (node?.playerLayer.isReadyForDisplay != true || (node?.isActive == true && node?.snapshot.state == .paused) || node?.snapshot.state == .failed)) ||
            (node?.isActive != true && !observesWarmFrame) ||
            (node?.isActive == true && node?.snapshot.timeToFirstFrame != nil && (!capturesBackdrop || node?.needsBackdropCapture != true || captureBoundaries >= 12)) {
            node?.discardBackdropOutput()
            displayLink?.invalidate(); displayLink = nil; readyItem = nil
        } else if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(displayBoundary))
            link.add(to: .main, forMode: .common); displayLink = link
        }
    }

    @objc private func displayBoundary() {
        if let node, node.isActive, node.snapshot.timeToFirstFrame != nil {
            guard capturesBackdrop, node.needsBackdropCapture, captureBoundaries < 12 else {
                node.discardBackdropOutput()
                displayLink?.invalidate(); displayLink = nil
                return
            }
            captureBoundaries += 1
        }
        if capturesBackdrop, node?.playerLayer.isReadyForDisplay != true {
            node?.discardBackdropOutput()
            displayLink?.invalidate(); displayLink = nil; readyItem = nil
            return
        }
        guard isPlaybackVisible, let node, let window, !isHidden,
              convert(bounds, to: window).intersects(window.bounds) else {
            readyItem = nil; return
        }
        guard
              !node.isSeekingFrame, hostedLayer?.frame == bounds,
              hostedLayer?.superlayer === layer, hostedLayer?.isReadyForDisplay == true,
              hostedLayer?.opacity == 1, bounds.width > 0, bounds.height > 0,
              convert(bounds, to: window).intersects(window.bounds) else { readyItem = nil; return }
        let activation = node.snapshot.activationID
        // Observe the incoming warm layer during the animation as well. A
        // continuously ready, visible frame has already crossed a display
        // boundary before commit; a new activation need not render it again.
        // Item identity and attachment/visibility resets prevent recycled or
        // offscreen frames from satisfying this proof. The timestamp remains
        // this post-commit boundary, never a preroll or pre-commit timestamp.
        guard readyItem == node.item, readyRevision == node.displayRevision else {
            readyItem = node.item; readyRevision = node.displayRevision; return
        }
        if node.isActive { node.didDisplayFrame(activation: activation, at: ProcessInfo.processInfo.systemUptime) }
        if capturesBackdrop, node.isActive, node.snapshot.timeToFirstFrame != nil, node.needsBackdropCapture {
            node.captureBackdropPoster()
        }
        guard node.isActive else { return }
        // First-frame metrics may already have copied this output frame. Wait for
        // the next decoded frame if the still is unavailable; do not decode again.
        if !capturesBackdrop || !node.needsBackdropCapture || captureBoundaries >= 12 {
            node.discardBackdropOutput()
            displayLink?.invalidate(); displayLink = nil
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { node?.discardBackdropOutput(); displayLink?.invalidate(); displayLink = nil; readyItem = nil }
        else { attach(node, gravity: hostedLayer?.videoGravity ?? .resizeAspectFill) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if hostedLayer?.frame != bounds { hostedLayer?.frame = bounds }
        CATransaction.commit()
        refreshDisplayLink()
    }
}
#endif
