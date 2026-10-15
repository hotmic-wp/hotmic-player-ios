#if canImport(UIKit) && !os(watchOS)
import SwiftUI
import UIKit

struct HMSurfaceHooks {
    var layout = HMVideoLayout()
    var fullscreenLayout: HMVideoLayout?
    var excludedRegions: [CGRect] = []
    var captionInsets = HMVideoInsets.zero
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
    static func position(_ current: TimeInterval, duration: TimeInterval) -> String {
        String.localizedStringWithFormat(text("%1$lld of %2$lld seconds"), Int64(max(0, current.isFinite ? current : 0)), Int64(max(0, duration.isFinite ? duration : 0)))
    }
}
private struct HMSurfaceHooksKey: EnvironmentKey { static let defaultValue = HMSurfaceHooks() }
private struct HMHitSpaceKey: EnvironmentKey { static let defaultValue: UUID? = nil }
private struct HMReservedRegionsKey: EnvironmentKey { static let defaultValue: [CGRect] = [] }
private struct HMFeedPagingDisabledKey: EnvironmentKey { static let defaultValue = false }
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
    var hmFeedPagingDisabled: Bool {
        get { self[HMFeedPagingDisabledKey.self] }
        set { self[HMFeedPagingDisabledKey.self] = newValue }
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
    /// Reserves additional surface-edge space for captions. Registered hit areas are also excluded.
    func hmCaptionInsets(_ insets: HMVideoInsets) -> some View {
        transformEnvironment(\.hmSurfaceHooks) { $0.captionInsets = insets }
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
    /// Blocks swipe paging in descendant feeds while true, alongside fullscreen and ad blocking.
    /// Programmatic navigation, inline surfaces and nested scroll views are unaffected.
    func hmFeedPagingDisabled(_ disabled: Bool) -> some View {
        environment(\.hmFeedPagingDisabled, disabled)
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
    var title: String? = nil
    var snapshot = HMPlaybackSnapshot()
    var muted = false
    var captions = false
    var hasCaptions = false
    var toggleMute: () -> Void = {}
    var toggleCaptions: () -> Void = {}
    var seek: (TimeInterval) -> Void = { _ in }
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
        view.isAccessibilityElement = false
        view.videoElement.accessibilityLabel = title ?? hooks.accessibilityLabel
        view.videoElement.accessibilityValue = "\(HMVideoAccessibility.value(state)), \(HMVideoAccessibility.position(snapshot.currentTime, duration: snapshot.duration)), \(HMVideoAccessibility.text(muted ? "Muted" : "Audio on")), \(HMVideoAccessibility.text(captions ? "Captions on" : "Captions off"))"
        view.videoElement.accessibilityTraits = [.button, .startsMediaSession]
        view.mute = toggleMute; view.caption = toggleCaptions
        view.progressElement.position = snapshot.currentTime
        view.progressElement.start = snapshot.seekableStart
        view.progressElement.duration = snapshot.seekableDuration
        view.progressElement.seek = seek
        view.progressElement.accessibilityLabel = HMVideoAccessibility.text("Playback position")
        view.progressElement.accessibilityValue = "\(HMVideoAccessibility.position(snapshot.currentTime, duration: snapshot.duration))"
        view.updateActions(wantsPlayback: wantsPlayback, muted: muted, captions: captions, hasCaptions: hasCaptions)
        view.accessibilityElements = view.enabled ? (snapshot.seekableDuration > 0 ? [view.videoElement, view.progressElement] : [view.videoElement]) : []
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
    var mute: (() -> Void)?
    var caption: (() -> Void)?
    lazy var videoElement = HMVideoAccessibilityElement(accessibilityContainer: self)
    lazy var progressElement = HMProgressAccessibilityElement(accessibilityContainer: self)
    private lazy var muteAction = UIAccessibilityCustomAction(name: "", actionHandler: { [weak self] _ in
        guard let self, self.enabled else { return false }; self.mute?(); return true
    })
    private lazy var captionAction = UIAccessibilityCustomAction(name: "", actionHandler: { [weak self] _ in
        guard let self, self.enabled else { return false }; self.caption?(); return true
    })
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
    func updateActions(wantsPlayback: Bool, muted: Bool = false, captions: Bool = false, hasCaptions: Bool = false) {
        let name = HMVideoAccessibility.text(wantsPlayback ? "Pause" : "Play")
        let configuration = "\(enabled)|\(onDoubleTap != nil)|\(name)|\(muted)|\(captions)|\(hasCaptions)"
        guard configuration != actionConfiguration else { return }
        actionConfiguration = configuration
        playbackAction.name = name
        muteAction.name = HMVideoAccessibility.text(muted ? "Unmute" : "Mute")
        captionAction.name = HMVideoAccessibility.text(captions ? "Captions off" : "Captions on")
        var actions = [playbackAction, muteAction]
        if hasCaptions { actions.append(captionAction) }
        if onDoubleTap != nil { actions.append(fireAction) }
        videoElement.accessibilityCustomActions = enabled ? actions : []
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
        videoElement.accessibilityIdentifier = "hm-video-surface"
        progressElement.accessibilityIdentifier = "hm-playback-position"
        progressElement.accessibilityTraits = .adjustable
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
    override func layoutSubviews() {
        super.layoutSubviews()
        videoElement.accessibilityFrameInContainerSpace = videoFrame
        progressElement.accessibilityFrameInContainerSpace = CGRect(x: videoFrame.minX, y: max(videoFrame.minY, videoFrame.maxY - 44), width: videoFrame.width, height: min(44, videoFrame.height))
        onFrameChange?(self)
    }
    override func accessibilityActivate() -> Bool { guard enabled else { return false }; onTap?(); return true }
    @objc private func tap() { if enabled { onTap?() } }
    @objc private func fire(_ recognizer: UITapGestureRecognizer) {
        guard enabled, onDoubleTap != nil else { return }
        // Event timestamps remain ordered even if the main run loop delivers a queued tap batch late.
        lastFire = fireTouch?.timestamp ?? ProcessInfo.processInfo.systemUptime
        onDoubleTap?(recognizer.location(in: self))
    }
}
final class HMVideoAccessibilityElement: UIAccessibilityElement {
    override func accessibilityActivate() -> Bool { (accessibilityContainer as? HMVideoGestureView)?.accessibilityActivate() ?? false }
}
final class HMProgressAccessibilityElement: UIAccessibilityElement {
    var position: TimeInterval = 0
    var start: TimeInterval = 0
    var duration: TimeInterval = 0
    var seek: ((TimeInterval) -> Void)?
    override func accessibilityIncrement() { adjust(true) }
    override func accessibilityDecrement() { adjust(false) }
    private func adjust(_ increment: Bool) {
        guard (accessibilityContainer as? HMVideoGestureView)?.enabled == true, duration > 0 else { return }
        seek?(HMAccessibility.seekTarget(position: position, start: start, duration: duration, increment: increment))
    }
}
#endif
