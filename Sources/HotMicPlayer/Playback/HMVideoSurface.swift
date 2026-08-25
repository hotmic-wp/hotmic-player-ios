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

    private let node: HMPlayerNode?
    private let gravity: AVLayerVideoGravity

    public init(node: HMPlayerNode?, gravity: AVLayerVideoGravity = .resizeAspectFill) {
        self.node = node
        self.gravity = gravity
    }

    public func makeUIView(context: Context) -> HMVideoSurfaceView {
        let view = HMVideoSurfaceView()
        view.backgroundColor = .black
        view.attach(node?.playerLayer, gravity: gravity)
        return view
    }

    public func updateUIView(_ uiView: HMVideoSurfaceView, context: Context) {
        uiView.attach(node?.playerLayer, gravity: gravity)
    }
}

/// Plain `UIView` whose only job is to own and size one `AVPlayerLayer`.
public final class HMVideoSurfaceView: UIView {

    private weak var hostedLayer: AVPlayerLayer?

    func attach(_ layer: AVPlayerLayer?, gravity: AVLayerVideoGravity) {
        guard hostedLayer !== layer else {
            hostedLayer?.videoGravity = gravity
            return
        }
        hostedLayer?.removeFromSuperlayer()
        hostedLayer = layer
        guard let layer else { return }
        layer.videoGravity = gravity
        // The layer travels between cells as its node is recycled, so it may
        // still be parented somewhere else.
        layer.removeFromSuperlayer()
        self.layer.addSublayer(layer)
        setNeedsLayout()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // No implicit animation: the layer is repositioned during scrolling and
        // a 0.25s default animation reads as the video sliding around.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostedLayer?.frame = bounds
        CATransaction.commit()
    }
}
#endif
