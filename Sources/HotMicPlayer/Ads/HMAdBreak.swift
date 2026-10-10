import Foundation
import Observation

/// The renderer responsible for a pre-roll. Companion/sidecar units remain host overlays.
public enum HMAdKind: String, Sendable, Equatable {
    /// The player renders a URL pre-roll using AVFoundation.
    case player
    /// The host SDK renders into the supplied safe-area container.
    case host
}

/// Media-time progress. Unknown duration is zero; fraction is nil until known.
public struct HMAdProgress: Sendable, Equatable {
    /// Elapsed ad media time in seconds, clamped to a finite nonnegative value.
    public let elapsed: TimeInterval
    /// Total ad duration in seconds, or zero when unknown.
    public let duration: TimeInterval
    /// Progress clamped to 0...1, or nil until duration is known.
    public var fraction: Double? { duration > 0 ? min(1, elapsed / duration) : nil }
    /// Creates sanitized progress from SDK or media-clock values.
    public init(elapsed: TimeInterval = 0, duration: TimeInterval = 0) {
        self.elapsed = elapsed.isFinite ? max(0, elapsed) : 0
        self.duration = duration.isFinite ? max(0, duration) : 0
    }
}

/// Observable break lifecycle for host comment/preview/squeezeback suppression.
public enum HMAdState: Sendable, Equatable {
    /// No break consulted for the current visit.
    case none
    /// Awaiting a decision or a URL ad's first frame.
    case loading
    /// A break is active. Read HMPlayer.adProgress for media-time progress.
    case playing(kind: HMAdKind)
    /// The current visit's decision/break ended, including no fill or timeout.
    case finished
    /// True during loading/playing; suppress comment affordances and squeezeback.
    public var isActive: Bool {
        switch self { case .loading, .playing: return true; case .none, .finished: return false }
    }
}

/// Terminal outcome, emitted exactly once per consulted visit (including no fill).
public enum HMAdOutcome: String, Sendable, Equatable {
    /// The ad finished normally.
    case completed
    /// The host skipped the ad.
    case skipped
    /// Decisioning or ad playback failed; content may continue.
    case failed
    /// The decision, startup, break duration or progress exceeded its deadline.
    case timedOut
    /// The provider chose content without an ad.
    case noFill
    /// A swipe, replacement or teardown cancelled the active visit.
    case cancelled
}

#if canImport(UIKit) && !os(watchOS)
import UIKit

/// Host decisioning stays in the existing ad stack. Called once per item visit,
/// before content activation. Return promptly; late host adapters are stopped as cancelled.
@MainActor public protocol HMAdBreakProvider: AnyObject {
    /// Selects an optional pre-roll; a late host adapter receives stop(.cancelled).
    func adBreak(for item: HMMediaItem) async throws -> HMAdBreak
}

/// A visit's decision. A URL item must contain a directly playable MP4/HLS/file URL.
@MainActor public enum HMAdBreak {
    /// Continue to content immediately.
    case none
    /// Play a directly accessible MP4/HLS/file URL with aspect fit.
    case preRoll(HMMediaItem)
    /// Yield rendering to an existing host SDK.
    case hostPlayed(HMHostAdBreak)
}

/// Host SDK adapter. Start renders into context.container; stop releases all SDK
/// work on completion, skip, failure, timeout, swipe-away or teardown. No SDK UI is added.
@MainActor public struct HMHostAdBreak {
    /// Starts the SDK with a visit-scoped container and completion callbacks.
    public let start: (HMHostAdContext) -> Void
    /// Releases the SDK once on any terminal outcome, including cancellation.
    public let stop: (HMAdOutcome) -> Void
    /// Creates an adapter with an optional terminal cleanup callback.
    public init(start: @escaping (HMHostAdContext) -> Void, stop: @escaping (HMAdOutcome) -> Void = { _ in }) {
        self.start = start; self.stop = stop
    }
}

/// One visit's safe-area container and callbacks. Retaining an old context is safe:
/// after it ends, all callbacks are inert. Host owns beacons, skip UI and countdown.
@MainActor @Observable public final class HMHostAdContext {
    /// Safe-area view above content and below host overlays; mount your SDK here.
    public let container = UIView()
    /// Whether the SDK may play audio/video. Honour changes on pause and visibility transitions.
    public private(set) var isPlaybackAllowed = false
    /// SDK pause/resume bridge. Set during start and also read the initial isPlaybackAllowed value.
    @ObservationIgnored public var onPlaybackAllowedChange: ((Bool) -> Void)?
    @ObservationIgnored private var finish: ((HMAdOutcome) -> Void)?
    @ObservationIgnored private var progress: ((HMAdProgress) -> Void)?
    init(finish: @escaping (HMAdOutcome) -> Void, progress: @escaping (HMAdProgress) -> Void) {
        self.finish = finish; self.progress = progress
        container.backgroundColor = .black
        container.clipsToBounds = true
    }
    /// Ends this visit normally. Inert after the first terminal callback.
    public func complete() { finish?(.completed) }
    /// Ends this visit as skipped. The host controls skip eligibility.
    public func skip() { finish?(.skipped) }
    /// Reports SDK failure and yields to content.
    public func fail() { finish?(.failed) }
    /// Publishes host SDK media progress while this visit is active.
    public func updateProgress(_ value: HMAdProgress) { progress?(value) }
    func setPlaybackAllowed(_ allowed: Bool) {
        guard allowed != isPlaybackAllowed else { return }
        isPlaybackAllowed = allowed; onPlaybackAllowedChange?(allowed)
    }
    func invalidate() {
        finish = nil; progress = nil
        setPlaybackAllowed(false); onPlaybackAllowedChange = nil
        container.removeFromSuperview()
    }
}
#endif
