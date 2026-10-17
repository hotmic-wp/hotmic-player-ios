import Foundation
import Observation

/// The renderer responsible for a pre-roll or a companion ad.
public enum HMAdKind: String, Sendable, Equatable {
    /// The player renders a URL creative using AVFoundation.
    case player
    /// The host SDK renders into the supplied container.
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

/// Terminal outcome, emitted exactly once per consulted visit (including no fill), and once per armed companion.
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
    /// The decision armed a companion ad. Content started without a pre-roll; the companion reports
    /// its own outcome through `HMPlayerEvent.companionEnded`.
    case companion
}

/// Which watched time a companion trigger counts. Watched time is content actually watched,
/// summed from positive playhead progress while content plays; it is never a playhead position.
public enum HMWatchedTimeScope: String, Sendable, Equatable, Codable {
    /// Watched time since the companion was armed, across items. Swipes never reset it.
    case session
    /// Watched time on the current item since the viewer joined it. Restarts on each item change.
    case item
}

/// When an armed companion appears. Values are sanitized when used: nonfinite or negative
/// values use the defaults, and the countdown is clamped to `0...watchedTime`.
public struct HMCompanionTrigger: Sendable, Equatable {
    /// Watched seconds after arming before the companion appears. Default 10.
    public var watchedTime: TimeInterval
    /// Watched seconds of visible countdown before the companion appears. Default 5; zero shows none.
    public var countdown: TimeInterval
    /// Which watched time counts. Default `.session`.
    public var scope: HMWatchedTimeScope
    /// Creates a trigger. The defaults appear after 10 watched seconds, with a 5-second countdown, across items.
    public init(watchedTime: TimeInterval = 10, countdown: TimeInterval = 5, scope: HMWatchedTimeScope = .session) {
        self.watchedTime = watchedTime; self.countdown = countdown; self.scope = scope
    }
    /// The trigger as the player applies it: defaults for invalid values, countdown clamped to the watched time.
    var sanitized: HMCompanionTrigger {
        let watched = watchedTime.isFinite && watchedTime >= 0 ? watchedTime : 10
        let visible = countdown.isFinite && countdown >= 0 ? countdown : 5
        return HMCompanionTrigger(watchedTime: watched, countdown: min(watched, visible), scope: scope)
    }
}

/// Player-level companion lifecycle. Unlike `HMAdState`, it never suppresses comments, chrome or the sheet.
public enum HMCompanionState: Sendable, Equatable {
    /// No companion is armed or shown.
    case none
    /// Accepted and counting watched time; nothing is visible.
    case armed
    /// The countdown is visible. Read `HMPlayer.companionCountdown` for its value.
    case countdown
    /// Shown in the companion band until it ends. Read `HMPlayer.companionProgress` for progress.
    case playing(kind: HMAdKind)
    /// True while the band is on screen.
    public var isPresented: Bool { if case .playing = self { return true } else { return false } }
}

/// Latest watched-time sample for an armed companion. Draw the countdown on the wall clock from
/// `estimatedRemaining(at:)`; samples arrive without events or analytics.
public struct HMCompanionCountdown: Sendable, Equatable {
    /// Watched seconds remaining until the companion appears, at `sampledAt`.
    public let remaining: TimeInterval
    /// Length of the visible countdown in watched seconds; the countdown shows while `remaining` is at or below it.
    public let countdownLength: TimeInterval
    /// Watched seconds gained per wall-clock second at `sampledAt`. Zero while content is not
    /// advancing, or while a visible countdown is frozen because the companion cannot appear.
    public let rate: Double
    /// `ProcessInfo.systemUptime` when the sample was taken.
    public let sampledAt: TimeInterval
    /// Estimated watched seconds remaining at an uptime, never below zero.
    public func estimatedRemaining(at uptime: TimeInterval) -> TimeInterval {
        max(0, remaining - max(0, uptime - sampledAt) * rate)
    }
}

#if canImport(UIKit) && !os(watchOS)
import UIKit

/// Host decisioning stays in the existing ad stack. Called once per item visit,
/// before content activation. Return promptly; late host adapters are stopped as cancelled.
@MainActor public protocol HMAdBreakProvider: AnyObject {
    /// Selects an optional pre-roll or companion; a late host adapter receives stop(.cancelled).
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
    /// Arms a companion ad. Content starts now; the creative appears in the companion band after
    /// the trigger's watched time and stays across items until it ends. Mutually exclusive with a
    /// pre-roll for this visit.
    case companion(HMCompanionBreak)
}

/// The creative behind a companion break.
@MainActor enum HMCompanionCreative {
    case media(HMMediaItem)
    case host(HMHostAdBreak)
}

/// A companion ad: a video ad shown in the companion band while content keeps playing, not a
/// VAST companion banner. It is decided in the pre-roll slot, stays across items until it ends,
/// and cannot be dismissed unless the host offers a close control.
@MainActor public struct HMCompanionBreak {
    let creative: HMCompanionCreative
    /// When the companion appears; nil uses `HMPlayerConfiguration.companionTrigger`.
    public var trigger: HMCompanionTrigger?
    /// Creative width divided by height. Sizes the companion band; default 16:9.
    public var aspectRatio: Double
    /// Destination for the ready-made "Learn more" control; nil hides it. Unused for host-rendered creatives.
    public var clickThroughURL: URL?
    /// The renderer that plays the creative.
    public var kind: HMAdKind { if case .host = creative { return .host } else { return .player } }
    /// A creative the player plays from a directly playable MP4, HLS or file URL. It starts muted.
    public static func media(_ item: HMMediaItem, clickThroughURL: URL? = nil,
                             aspectRatio: Double = 16 / 9, trigger: HMCompanionTrigger? = nil) -> HMCompanionBreak {
        HMCompanionBreak(creative: .media(item), trigger: trigger, aspectRatio: aspectRatio, clickThroughURL: clickThroughURL)
    }
    /// A creative a host SDK renders into `HMHostAdContext.container`, which is the companion band.
    /// `start` runs when the band appears, never earlier; preload during the decision if needed.
    public static func hostRendered(_ adapter: HMHostAdBreak, aspectRatio: Double = 16 / 9,
                                    trigger: HMCompanionTrigger? = nil) -> HMCompanionBreak {
        HMCompanionBreak(creative: .host(adapter), trigger: trigger, aspectRatio: aspectRatio, clickThroughURL: nil)
    }
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

/// One visit's or companion's container and callbacks. Retaining an old context is safe:
/// after it ends, all callbacks are inert. Host owns beacons, skip UI and countdown.
@MainActor @Observable public final class HMHostAdContext {
    /// For a pre-roll, a safe-area view above content and below host overlays. For a companion,
    /// the companion band. Mount your SDK here.
    public let container = UIView()
    /// Whether the SDK may play audio/video. Honour changes on pause and visibility transitions.
    public private(set) var isPlaybackAllowed = false
    /// SDK pause/resume bridge. Set during start and also read the initial isPlaybackAllowed value.
    @ObservationIgnored public var onPlaybackAllowedChange: ((Bool) -> Void)?
    /// The audio state the creative should apply. A companion starts muted and follows
    /// `HMPlayer.isCompanionMuted`; a pre-roll mirrors `HMPlayer.isMuted`.
    public private(set) var isMuted: Bool
    /// SDK mute bridge. Set during start and also read the initial `isMuted` value.
    @ObservationIgnored public var onMutedChange: ((Bool) -> Void)?
    @ObservationIgnored private var finish: ((HMAdOutcome) -> Void)?
    @ObservationIgnored private var progress: ((HMAdProgress) -> Void)?
    @ObservationIgnored private var reportedMute: ((Bool) -> Void)?
    init(finish: @escaping (HMAdOutcome) -> Void, progress: @escaping (HMAdProgress) -> Void,
         muted: Bool = false, reportMuted: ((Bool) -> Void)? = nil) {
        self.finish = finish; self.progress = progress; self.reportedMute = reportMuted
        isMuted = muted
        container.backgroundColor = .black
        container.clipsToBounds = true
    }
    /// Ends this visit normally. Inert after the first terminal callback.
    public func complete() { finish?(.completed) }
    /// Ends this visit as skipped, or a companion as closed by the viewer. The host controls eligibility.
    public func skip() { finish?(.skipped) }
    /// Reports SDK failure and yields to content.
    public func fail() { finish?(.failed) }
    /// Publishes host SDK media progress while this visit is active.
    public func updateProgress(_ value: HMAdProgress) { progress?(value) }
    /// Reports that the viewer toggled the SDK's own sound control. Companions only; ignored for pre-rolls.
    public func reportMuted(_ muted: Bool) { reportedMute?(muted) }
    func setPlaybackAllowed(_ allowed: Bool) {
        guard allowed != isPlaybackAllowed else { return }
        isPlaybackAllowed = allowed; onPlaybackAllowedChange?(allowed)
    }
    func setMuted(_ muted: Bool) {
        guard muted != isMuted else { return }
        isMuted = muted; onMutedChange?(muted)
    }
    func invalidate() {
        finish = nil; progress = nil; reportedMute = nil
        setPlaybackAllowed(false); onPlaybackAllowedChange = nil; onMutedChange = nil
        container.removeFromSuperview()
    }
}
#endif
