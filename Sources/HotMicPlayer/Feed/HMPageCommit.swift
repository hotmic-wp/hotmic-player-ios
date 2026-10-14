import Foundation

/// What made a page current, and the gesture clocks known when it did.
///
/// `time` is the activation clock (TTFF starts there). The gesture clocks are
/// on the same `systemUptime` clock, so analysis can re-anchor at any of them.
struct HMPageCommit: Equatable {
    enum Source: String {
        /// Finger lift, when the paging target is already known.
        case lift
        /// The scroll view settled after a user gesture.
        case settle
        /// An animated page move requested in code settled.
        case programmatic
        /// No settle callback arrived; the probe saw 0.2 s without motion.
        case quietFallback = "quiet-fallback"
        /// SwiftUI's scroll position changed and stayed put for 0.2 s.
        case scrollPositionFallback = "scroll-position-fallback"
        /// play(), next(), jump(toID:), requestPlay, a playlist edit, or a failure skip with no scroll callback.
        case api
    }
    var source: Source
    var time: TimeInterval
    /// The pan was recognised (`scrollViewWillBeginDragging`).
    var touch: TimeInterval?
    /// The finger lifted (`scrollViewWillEndDragging`).
    var lift: TimeInterval?
    /// The page came to rest.
    var settle: TimeInterval?
    /// A mismatch between the final target at lift and the settled destination.
    var correction: String?
    /// How the lift target was known: `target-offset`; unknown targets are never predicted.
    var liftTarget: String?
    /// Animated page moves issued for one request; above 1 means the first was interrupted.
    var attempts: Int?

    init(source: Source, time: TimeInterval, touch: TimeInterval? = nil, lift: TimeInterval? = nil,
         settle: TimeInterval? = nil, correction: String? = nil, liftTarget: String? = nil, attempts: Int? = nil) {
        self.source = source; self.time = time; self.touch = touch; self.lift = lift; self.settle = settle
        self.correction = correction; self.liftTarget = liftTarget; self.attempts = attempts
    }

    /// A user's finger produced this report.
    var isGesture: Bool { touch != nil }

    /// Clock metrics for analytics, named `<clock>_monotonic_s`.
    var clockMetrics: [String: Double] {
        var metrics: [String: Double] = [:]
        if let touch { metrics["touch_monotonic_s"] = touch }
        if let lift { metrics["lift_monotonic_s"] = lift }
        if let settle { metrics["settle_monotonic_s"] = settle }
        if let attempts { metrics["page_request_attempts"] = Double(attempts) }
        return metrics
    }
    var properties: [String: String] {
        var properties = ["commit_source": source.rawValue]
        if let correction { properties["commit_correction"] = correction }
        if let liftTarget { properties["lift_target"] = liftTarget }
        return properties
    }
}
