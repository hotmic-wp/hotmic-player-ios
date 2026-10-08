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
public struct HMVideoSurface: UIViewRepresentable {

    @Environment(\.scenePhase) private var scenePhase
    private let node: HMPlayerNode?
    private let gravity: AVLayerVideoGravity
    private let active: Bool
    private let activationID: String?

    public init(node: HMPlayerNode?, gravity: AVLayerVideoGravity = .resizeAspectFill) {
        self.node = node
        self.gravity = gravity
        self.active = node?.isActive ?? false
        self.activationID = node?.snapshot.activationID
    }

    public func makeUIView(context: Context) -> HMVideoSurfaceView {
        let view = HMVideoSurfaceView()
        view.backgroundColor = .clear
        view.isPlaybackVisible = scenePhase == .active
        view.attach(node, gravity: gravity)
        return view
    }

    public func updateUIView(_ uiView: HMVideoSurfaceView, context: Context) {
        uiView.isPlaybackVisible = scenePhase == .active
        uiView.attach(node, gravity: gravity)
    }
}

/// Plain `UIView` whose only job is to own and size one `AVPlayerLayer`.
public final class HMVideoSurfaceView: UIView {

    private weak var hostedLayer: AVPlayerLayer?
    private weak var node: HMPlayerNode?
    private var displayLink: CADisplayLink?
    private var readyActivation: String?
    var isPlaybackVisible = true { didSet { refreshDisplayLink() } }

    func attach(_ node: HMPlayerNode?, gravity: AVLayerVideoGravity) {
        let layer = node?.playerLayer
        if hostedLayer !== layer {
            // A recycled layer may already belong to another surface.
            if hostedLayer?.superlayer === self.layer { hostedLayer?.removeFromSuperlayer() }
            hostedLayer = layer; self.node = node
            layer?.removeFromSuperlayer()
            if let layer { self.layer.addSublayer(layer) }
            readyActivation = nil
        }
        layer?.videoGravity = gravity
        setNeedsLayout()
        refreshDisplayLink()
    }

    public override var isHidden: Bool { didSet { refreshDisplayLink() } }

    private func refreshDisplayLink() {
        if !isPlaybackVisible || isHidden || node?.isActive != true || window == nil || node?.snapshot.timeToFirstFrame != nil {
            displayLink?.invalidate(); displayLink = nil; readyActivation = nil
        } else if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(displayBoundary))
            link.add(to: .main, forMode: .common); displayLink = link
        }
    }

    @objc private func displayBoundary() {
        guard isPlaybackVisible, let node, node.isActive, let window, !isHidden,
              convert(bounds, to: window).intersects(window.bounds) else {
            displayLink?.invalidate(); displayLink = nil; readyActivation = nil; return
        }
        guard
              hostedLayer?.superlayer === layer, hostedLayer?.isReadyForDisplay == true,
              hostedLayer?.opacity == 1, bounds.width > 0, bounds.height > 0,
              convert(bounds, to: window).intersects(window.bounds) else { readyActivation = nil; return }
        let activation = node.snapshot.activationID
        // The preceding boundary observed the ready, visible layer. Its
        // transaction has now crossed a display boundary, including warm swaps.
        guard readyActivation == activation else { readyActivation = activation; return }
        node.didDisplayFrame(activation: activation, at: ProcessInfo.processInfo.systemUptime)
        displayLink?.invalidate(); displayLink = nil
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { displayLink?.invalidate(); displayLink = nil; readyActivation = nil }
        else { attach(node, gravity: hostedLayer?.videoGravity ?? .resizeAspectFill) }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hostedLayer?.frame = bounds
        CATransaction.commit()
        refreshDisplayLink()
    }
}
#endif
