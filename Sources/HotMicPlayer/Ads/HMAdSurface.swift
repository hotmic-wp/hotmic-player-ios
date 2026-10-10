#if canImport(UIKit) && !os(watchOS)
import SwiftUI
import UIKit

/// Native sizing prevents a representable's ideal size from collapsing the ad layer.
/// The window's safe rectangle is intersected with the page, including full-bleed hosts.
struct HMAdSurface: UIViewRepresentable {
    let player: HMPlayer
    func makeUIView(context: Context) -> HMAdSurfaceView { HMAdSurfaceView() }
    func updateUIView(_ view: HMAdSurfaceView, context: Context) {
        view.video.isPlaybackVisible = player.isFeedVisible
        view.video.attach(player.adNode, gravity: .resizeAspect)
        view.setHostContainer(player.hostAdContext?.container)
    }
}

final class HMAdSurfaceView: UIView {
    let video = HMVideoSurfaceView()
    private weak var hostContainer: UIView?
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black; clipsToBounds = true
        video.isUserInteractionEnabled = false
        addSubview(video)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func setHostContainer(_ container: UIView?) {
        if hostContainer !== container {
            if hostContainer?.superview === self { hostContainer?.removeFromSuperview() }
            hostContainer = container
            if let container { container.removeFromSuperview(); addSubview(container) }
        }
        setNeedsLayout()
    }
    override func didMoveToWindow() { super.didMoveToWindow(); setNeedsLayout() }
    override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); setNeedsLayout() }
    override func layoutSubviews() {
        super.layoutSubviews()
        let viewport = window.map { convert($0.safeAreaLayoutGuide.layoutFrame, from: $0).intersection(bounds) } ?? bounds
        let frame = viewport.isNull ? .zero : viewport
        video.frame = frame; hostContainer?.frame = frame
    }
}
#endif
