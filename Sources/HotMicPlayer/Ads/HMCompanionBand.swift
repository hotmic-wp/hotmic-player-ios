#if canImport(UIKit) && !os(watchOS)
import SwiftUI
import UIKit

/// Geometry of the companion band inside the feed: full width, sized by the creative's aspect
/// ratio, capped at a third of the inset viewport, docked above host chrome and the bottom safe area.
struct HMCompanionBandMetrics: Equatable {
    /// The band never takes more than this fraction of the viewport above its dock.
    static let maximumViewportFraction: CGFloat = 1 / 3
    /// The band's frame in feed coordinates.
    let frame: CGRect
    /// Height reserved below the band for host chrome and the bottom safe area.
    let dock: CGFloat
    init(bounds: CGRect, bottomInset: CGFloat, aspectRatio: Double) {
        let dock = bottomInset.isFinite ? max(0, bottomInset) : 0
        let ratio = aspectRatio.isFinite && aspectRatio > 0 ? CGFloat(aspectRatio) : 16 / 9
        let available = max(0, bounds.height - dock)
        let height = max(0, min(bounds.width / ratio, available * Self.maximumViewportFraction))
        self.dock = dock
        frame = CGRect(x: bounds.minX, y: bounds.maxY - dock - height, width: bounds.width, height: height)
    }
    /// The viewport every page keeps while the band is shown, intersected with a host squeeze target.
    func squeeze(intersecting target: CGRect?) -> CGRect {
        let own = CGRect(x: frame.minX, y: 0, width: frame.width, height: max(0, frame.minY))
        guard let target else { return own }
        let clipped = own.intersection(target)
        return clipped.isNull ? CGRect(origin: own.origin, size: CGSize(width: own.width, height: 0)) : clipped
    }
    /// The slide animation for the band and the squeeze; nil under Reduce Motion.
    static func slideAnimation(reduceMotion: Bool) -> Animation? { reduceMotion ? nil : .easeInOut(duration: 0.3) }
}

private struct HMCompanionBandKey: EnvironmentKey { static let defaultValue: CGRect? = nil }
extension EnvironmentValues {
    /// The presented companion band in feed coordinates, for pages to reserve and report.
    var hmCompanionBand: CGRect? {
        get { self[HMCompanionBandKey.self] }
        set { self[HMCompanionBandKey.self] = newValue }
    }
}

/// The band's native surface: the companion engine's layer or the host SDK's container.
/// Native sizing keeps the layer from collapsing, as for the pre-roll surface.
struct HMCompanionBandSurface: UIViewRepresentable {
    let player: HMPlayer
    func makeUIView(context: Context) -> HMCompanionBandView {
        let view = HMCompanionBandView()
        view.onWindowChange = { [weak player] mounted in player?.setCompanionBandMounted(mounted) }
        return view
    }
    func updateUIView(_ view: HMCompanionBandView, context: Context) {
        view.onWindowChange = { [weak player] mounted in player?.setCompanionBandMounted(mounted) }
        view.video.isPlaybackVisible = player.isFeedVisible
        view.video.attach(player.companionNode, gravity: .resizeAspect)
        view.setHostContainer(player.companionHostContext?.container)
    }
    static func dismantleUIView(_ view: HMCompanionBandView, coordinator: ()) { view.onWindowChange = nil }
}

final class HMCompanionBandView: UIView {
    let video = HMVideoSurfaceView()
    var onWindowChange: ((Bool) -> Void)?
    private weak var hostContainer: UIView?
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black; clipsToBounds = true
        video.isUserInteractionEnabled = false
        addSubview(video)
        isAccessibilityElement = true
        accessibilityLabel = HMVideoAccessibility.text("Advertisement")
        accessibilityIdentifier = "hm-companion-band"
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func setHostContainer(_ container: UIView?) {
        if hostContainer !== container {
            if hostContainer?.superview === self { hostContainer?.removeFromSuperview() }
            hostContainer = container
            if let container { container.removeFromSuperview(); addSubview(container) }
        }
        // A host SDK keeps its own accessible controls; a player creative reads as one advertisement.
        isAccessibilityElement = container == nil
        setNeedsLayout()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?(window != nil)
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        video.frame = bounds; hostContainer?.frame = bounds
    }
}
#endif
