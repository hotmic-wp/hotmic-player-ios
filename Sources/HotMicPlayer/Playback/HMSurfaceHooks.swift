#if canImport(UIKit) && !os(watchOS)
import SwiftUI
import UIKit

struct HMSurfaceHooks {
    var layout = HMVideoLayout()
    var fullscreenLayout: HMVideoLayout?
    var excludedRegions: [CGRect] = []
    var isAdPlaying = false
    var accessibilityLabel = HMVideoAccessibility.text("Video")
    var onTap: (() -> Void)?
    var onDoubleTap: ((CGPoint) -> Void)?
    var onFrameChange: ((HMVideoGestureView) -> Void)?
    var coordinateReference: (() -> UIView?)?
    var forFullscreen: Self {
        var result = self
        result.layout = fullscreenLayout ?? HMVideoLayout()
        result.excludedRegions = []
        result.onFrameChange = nil
        result.coordinateReference = nil
        return result
    }
}
enum HMVideoAccessibility {
    static func text(_ key: String) -> String { NSLocalizedString(key, bundle: .module, comment: "Video accessibility") }
    static func value(_ state: HMPlaybackState) -> String { text(state.rawValue.capitalized) }
}
private struct HMSurfaceHooksKey: EnvironmentKey { static let defaultValue = HMSurfaceHooks() }
private struct HMHitSpaceKey: EnvironmentKey { static let defaultValue: UUID? = nil }
private struct HMReservedRegionsKey: EnvironmentKey { static let defaultValue: [CGRect] = [] }
struct HMHitAreaPreference: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}
extension EnvironmentValues {
    var hmSurfaceHooks: HMSurfaceHooks {
        get { self[HMSurfaceHooksKey.self] }
        set { self[HMSurfaceHooksKey.self] = newValue }
    }
    var hmHitSpace: UUID? {
        get { self[HMHitSpaceKey.self] }
        set { self[HMHitSpaceKey.self] = newValue }
    }
}
public extension EnvironmentValues {
    /// Registered overlay and explicit host rectangles in the current surface's coordinates.
    var hmReservedRegions: [CGRect] {
        get { self[HMReservedRegionsKey.self] }
        set { self[HMReservedRegionsKey.self] = newValue }
    }
}
public extension View {
    /// Applies viewport insets and a host-driven squeeze target to feed or inline video.
    func hmVideoLayout(_ layout: HMVideoLayout) -> some View {
        transformEnvironment(\.hmSurfaceHooks) { $0.layout = layout }
    }
    /// Separate fullscreen layout; defaults to zero insets and no squeeze. Inline explicit hit areas are dropped.
    func hmFullscreenVideoLayout(_ layout: HMVideoLayout) -> some View {
        transformEnvironment(\.hmSurfaceHooks) { $0.fullscreenLayout = layout }
    }
    /// Replaces default play/pause on single tap; double tap reports surface coordinates.
    /// UIKit's double-tap failure dependency is the only single-tap delay (system interval, typically ~0.3s).
    /// Fullscreen stays enabled. Ad playback suppresses gestures and accessibility actions.
    func hmVideoGestures(isAdPlaying: Bool = false, accessibilityLabel: String? = nil,
                         onTap: (() -> Void)? = nil, onDoubleTap: ((CGPoint) -> Void)? = nil) -> some View {
        transformEnvironment(\.hmSurfaceHooks) {
            $0.isAdPlaying = isAdPlaying; $0.accessibilityLabel = accessibilityLabel ?? HMVideoAccessibility.text("Video")
            $0.onTap = onTap; $0.onDoubleTap = onDoubleTap
        }
    }
    /// Registers rectangles in surface coordinates (also available via hmReservedRegions).
    func hmExcludedHitAreas(_ regions: [CGRect]) -> some View {
        transformEnvironment(\.hmSurfaceHooks) { $0.excludedRegions = regions }
    }
    /// Reserves this view's bounds automatically for gesture exclusion and sidecar placement.
    func hmExcludedHitArea() -> some View { modifier(HMExcludedHitAreaModifier()) }
}
private struct HMExcludedHitAreaModifier: ViewModifier {
    @Environment(\.hmHitSpace) private var space
    func body(content: Content) -> some View {
        content.background {
            if let space {
                GeometryReader { geometry in
                    Color.clear.preference(key: HMHitAreaPreference.self, value: [geometry.frame(in: .named(space))])
                }.allowsHitTesting(false)
            }
        }
    }
}
/// Container for tappable host overlays. Its entire bounds are automatically excluded and reserved.
/// Use one per rail, metadata block, comment preview or sidecar; avoid wrapping the whole screen.
public struct HMHitArea<Content: View>: View {
    private let content: Content
    /// Creates an overlay container whose full bounds are reserved from video gestures.
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View { content.hmExcludedHitArea() }
}

/// Native recognizers sit behind overlays, so SwiftUI controls receive their own touches.
/// Explicit reservations also protect noninteractive metadata and UIKit sibling overlays.
struct HMVideoGestureSurface: UIViewRepresentable {
    var hooks: HMSurfaceHooks
    var videoFrame: CGRect
    var viewport: CGRect
    var regions: [CGRect]
    var state: HMPlaybackState
    var wantsPlayback: Bool
    var enabled: Bool
    var toggle: () -> Void
    func makeUIView(context: Context) -> HMVideoGestureView { HMVideoGestureView() }
    func updateUIView(_ view: HMVideoGestureView, context: Context) {
        view.onFrameChange = hooks.onFrameChange
        view.videoFrame = videoFrame; view.viewport = viewport
        view.regions = regions.filter { !hooks.excludedRegions.contains($0) }
        view.hostRegions = hooks.excludedRegions
        view.coordinateReference = hooks.coordinateReference
        view.enabled = enabled && !hooks.isAdPlaying && !videoFrame.isEmpty
        view.onTap = hooks.onTap ?? toggle; view.toggle = toggle
        view.onDoubleTap = hooks.onDoubleTap.map { callback in
            { [weak view] point in
                if let view, let reference = hooks.coordinateReference?() { callback(view.convert(point, to: reference)) }
                else { callback(point) }
            }
        }
        view.isAccessibilityElement = view.enabled
        view.accessibilityLabel = hooks.accessibilityLabel
        view.accessibilityValue = HMVideoAccessibility.value(state)
        view.accessibilityTraits = [.button, .startsMediaSession]
        view.updateActions(wantsPlayback: wantsPlayback)
        // With no Fire callback there is no reason to wait for a second tap.
        view.doubleTap.isEnabled = hooks.onDoubleTap != nil && view.enabled
        view.rapidTap.isEnabled = view.doubleTap.isEnabled
        view.singleTap.isEnabled = view.enabled
    }
}
final class HMVideoGestureView: UIView, UIGestureRecognizerDelegate {
    var videoFrame = CGRect.zero { didSet { if oldValue != videoFrame { setNeedsLayout() } } }
    var viewport = CGRect.zero
    var regions: [CGRect] = []
    var hostRegions: [CGRect] = []
    var coordinateReference: (() -> UIView?)?
    var enabled = true { didSet { if !enabled { lastFire = nil } } }
    var onTap: (() -> Void)?
    var onDoubleTap: ((CGPoint) -> Void)? { didSet { if onDoubleTap == nil { lastFire = nil } } }
    var toggle: (() -> Void)?
    var onFrameChange: ((HMVideoGestureView) -> Void)?
    /// UIKit owns initial double-tap timing. Further taps within 0.3s of Fire extend a Fire streak.
    static let fireContinuationInterval: TimeInterval = 0.3
    private var lastFire: TimeInterval?
    private weak var fireTouch: UITouch?
    private var actionConfiguration: String?
    private lazy var playbackAction = UIAccessibilityCustomAction(name: "", actionHandler: { [weak self] _ in
        guard let self, self.enabled else { return false }; self.toggle?(); return true
    })
    private lazy var fireAction = UIAccessibilityCustomAction(name: HMVideoAccessibility.text("Fire"), actionHandler: { [weak self] _ in
        guard let self, self.enabled, self.onDoubleTap != nil else { return false }
        self.onDoubleTap?(CGPoint(x: self.videoFrame.midX, y: self.videoFrame.midY)); return true
    })
    func updateActions(wantsPlayback: Bool) {
        let name = HMVideoAccessibility.text(wantsPlayback ? "Pause" : "Play")
        let configuration = "\(enabled)|\(onDoubleTap != nil)|\(name)"
        guard configuration != actionConfiguration else { return }
        actionConfiguration = configuration
        playbackAction.name = name
        accessibilityCustomActions = enabled ? (onDoubleTap == nil ? [playbackAction] : [playbackAction, fireAction]) : []
    }
    private(set) lazy var singleTap = UITapGestureRecognizer(target: self, action: #selector(tap))
    private(set) lazy var doubleTap = UITapGestureRecognizer(target: self, action: #selector(fire(_:)))
    private(set) lazy var rapidTap = UITapGestureRecognizer(target: self, action: #selector(fire(_:)))
    override init(frame: CGRect) {
        super.init(frame: frame)
        doubleTap.numberOfTapsRequired = 2
        singleTap.delegate = self; doubleTap.delegate = self; rapidTap.delegate = self
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap); addGestureRecognizer(doubleTap); addGestureRecognizer(rapidTap)
        accessibilityIdentifier = "hm-video-surface"
        backgroundColor = .clear
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let continuing = lastFire.map { touch.timestamp - $0 >= 0 && touch.timestamp - $0 <= Self.fireContinuationInterval } ?? false
        if (gestureRecognizer === rapidTap) != continuing { return false }
        let accepted = acceptsTap(at: touch.location(in: self), isDoubleTap: gestureRecognizer !== singleTap)
        if accepted, gestureRecognizer !== singleTap { fireTouch = touch }
        return accepted
    }
    func acceptsTap(at point: CGPoint, isDoubleTap: Bool) -> Bool {
        enabled && HMOverlayRegions.acceptsTap(at: point, videoFrame: isDoubleTap ? viewport : videoFrame, excluding: exclusions)
    }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        enabled && HMOverlayRegions.acceptsTap(at: point, videoFrame: viewport, excluding: exclusions)
    }
    private var exclusions: [CGRect] {
        let reference = coordinateReference?()
        return regions + hostRegions.map { rect in reference.map { convert(rect, from: $0) } ?? rect }
    }
    override func layoutSubviews() { super.layoutSubviews(); onFrameChange?(self) }
    override func accessibilityActivate() -> Bool { guard enabled else { return false }; onTap?(); return true }
    @objc private func tap() { if enabled { onTap?() } }
    @objc private func fire(_ recognizer: UITapGestureRecognizer) {
        guard enabled, onDoubleTap != nil else { return }
        // Event timestamps remain ordered even if the main run loop delivers a queued tap batch late.
        lastFire = fireTouch?.timestamp ?? ProcessInfo.processInfo.systemUptime
        onDoubleTap?(recognizer.location(in: self))
    }
}
#endif
