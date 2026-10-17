import Foundation

/// Sums watched content seconds from positive playhead progress. It never reads the playhead as
/// a position: a tick adds `max(0, Δplayhead)`, capped by the elapsed wall time plus a tolerance,
/// so seeks, loops, stalls and a sliding live window add nothing.
struct HMWatchedTimeClock {
    /// Slack allowed between playhead and wall-clock progress within one tick.
    static let tolerance: TimeInterval = 0.25
    /// A clock without a tick for longer than this is treated as stopped.
    static let staleInterval: TimeInterval = 0.35
    /// Watched seconds accrued since the last reset.
    private(set) var watched: TimeInterval = 0
    /// Watched seconds gained per wall-clock second at the last tick: 1 while advancing, 0 otherwise.
    private(set) var rate: Double = 0
    private var baseline: (playhead: TimeInterval, uptime: TimeInterval)?
    private var lastTickAt: TimeInterval?

    /// Records a playhead tick. `advancing` is whether content was actually playing at the tick;
    /// a tick that is not advancing drops the baseline so the next advancing tick starts fresh.
    /// Returns the watched seconds this tick added.
    @discardableResult
    mutating func record(_ snapshot: HMPlaybackSnapshot, advancing: Bool, at uptime: TimeInterval) -> TimeInterval {
        lastTickAt = uptime
        guard advancing, snapshot.currentTime.isFinite, uptime.isFinite else { baseline = nil; rate = 0; return 0 }
        defer { baseline = (snapshot.currentTime, uptime) }
        guard let baseline else { rate = 0; return 0 }
        let progress = snapshot.currentTime - baseline.playhead
        let wall = uptime - baseline.uptime
        guard progress > 0, wall >= 0 else { rate = 0; return 0 }
        let gained = min(progress, wall + Self.tolerance)
        watched += gained; rate = gained > 0 ? 1 : 0
        return gained
    }
    /// Drops the baseline after a seek, loop, stall, pause or item change; the next tick adds nothing.
    mutating func discontinuity() { baseline = nil; rate = 0 }
    /// Restarts the count at zero.
    mutating func reset() { watched = 0; baseline = nil; rate = 0 }
    /// True when ticks stopped arriving, which means content stopped advancing without a pause event.
    func isStale(at uptime: TimeInterval) -> Bool { lastTickAt.map { uptime - $0 > Self.staleInterval } ?? false }
}
