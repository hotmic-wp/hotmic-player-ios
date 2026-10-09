import Foundation

/// Measured-performance tuning. No network type or system network preferences are consulted.
public struct HMAdaptivePrefetchThresholds: Codable, Sendable, Equatable {
    /// Throughput below this is slow, in payload bytes/sec.
    public var slowBytesPerSecond: Double = 500_000
    /// Throughput at or above this is fast, in payload bytes/sec.
    public var fastBytesPerSecond: Double = 2_000_000
    /// Request time to response headers above this forces the slow plan.
    public var highLatencySeconds: Double = 0.4
    /// EWMA readiness hit rate below this triggers binge prioritisation.
    public var lowHitRate: Double = 0.7
    /// Dwell at or below this is binge pace.
    public var bingeDwellSeconds: Double = 2
    /// Dwell at or above this enables delayed, deeper starts.
    public var longDwellSeconds: Double = 8
    /// Pause below this buffer; the app start threshold also supplies a floor.
    public var safetyBufferSeconds: Double = 1.5
    /// Resume at this buffer, bounded below by safety and the app start threshold.
    public var recoveryBufferSeconds: Double = 3
    /// Fraction of the app per-item byte/time budget in slow conditions.
    public var slowBudgetFraction: Double = 0.25
    /// Fraction of the app budget before measurements or at medium speed.
    public var mediumBudgetFraction: Double = 0.5
    /// Increase the nearest two budgets by this factor when binge arrivals miss.
    public var bingeBudgetMultiplier: Double = 1.5
    /// Increase the per-item budget by this factor for long dwell.
    public var longDwellBudgetMultiplier: Double = 1.5
    /// Fraction of estimated dwell to wait before ready-player and disk work.
    public var longDwellDelayFraction: Double = 0.5
    /// Maximum long-dwell delay after activation.
    public var maximumDelaySeconds: Double = 6
    /// Slow-condition forward window, still bounded by the app ahead limit.
    public var slowAhead: Int = 2
    /// Unmeasured/medium-condition forward window, bounded by app limits.
    public var mediumAhead: Int = 3
    /// Desired slow-condition starting HLS bitrate, bits/sec.
    public var slowBitRate: Double = 600_000
    /// Desired unmeasured/medium starting HLS bitrate, bits/sec.
    public var mediumBitRate: Double = 1_000_000
    /// Desired fast-condition starting HLS bitrate, bits/sec.
    public var fastBitRate: Double = 3_000_000
    /// EWMA new-sample weight, clamped to 0...1.
    public var ewmaAlpha: Double = 0.25
    /// Creates the default tuning values.
    public init() {}
}

/// Smoothed telemetry and explicit hysteresis state; nil means no observation yet.
public struct HMPrefetchInputs: Codable, Sendable, Equatable {
    /// EWMA upstream payload rate; cache reads are excluded.
    public var throughputBytesPerSecond: Double?
    /// EWMA request time to response headers.
    public var latencySeconds: Double?
    /// EWMA fraction of forward arrivals with a ready player or disk start.
    public var readyHitRate: Double?
    /// EWMA wall time between forward activations.
    public var dwellSeconds: Double?
    /// Current playable buffer ahead of the playhead.
    public var bufferedAheadSeconds: Double
    /// Known VOD remainder; nil while duration is unknown.
    public var remainingSeconds: Double?
    /// Whether current playback is rebuffering.
    public var isStalling: Bool
    /// Previous safety pause, supplied explicitly for hysteresis.
    public var wasPaused: Bool
    /// Wall time since current activation.
    public var elapsedOnItemSeconds: Double
    /// Creates measured inputs, with unknown metrics represented by nil.
    public init(throughputBytesPerSecond: Double? = nil, latencySeconds: Double? = nil,
                readyHitRate: Double? = nil, dwellSeconds: Double? = nil,
                bufferedAheadSeconds: Double = 0, remainingSeconds: Double? = nil,
                isStalling: Bool = false, wasPaused: Bool = true, elapsedOnItemSeconds: Double = 0) {
        self.throughputBytesPerSecond = throughputBytesPerSecond; self.latencySeconds = latencySeconds
        self.readyHitRate = readyHitRate; self.dwellSeconds = dwellSeconds
        self.bufferedAheadSeconds = bufferedAheadSeconds; self.remainingSeconds = remainingSeconds
        self.isStalling = isStalling; self.wasPaused = wasPaused; self.elapsedOnItemSeconds = elapsedOnItemSeconds
    }
}

/// Tier 1 is a prerolled next player; tier 2 is a nearest-first disk prefix;
/// tier 3 resolves URL/poster only. Delay is measured from current activation.
public struct HMPrefetchPlan: Codable, Sendable, Equatable {
    /// Number of following entries to cache, nearest first.
    public var itemsAhead: Int
    /// Number of previous entries to cache, nearest first.
    public var itemsBehind: Int
    /// Maximum prefix payload bytes per entry.
    public var bytesPerItem: Int
    /// Optional media-time prefix budget, always bounded by bytes.
    public var secondsPerItem: Double?
    /// Whether to prepare a neighbour after the start delay.
    public var keepReadyPlayer: Bool
    /// Starting HLS ceiling in bits/sec; zero means unrestricted.
    public var startingBitRate: Double
    /// Maximum simultaneous explicit prefix transfers; zero admits none.
    public var concurrency: Int
    /// Safety pause for all speculative work.
    public var paused: Bool
    /// Earliest elapsed activation time for ready-player and disk work.
    public var startAfterSeconds: Double
    /// Human-readable decision reason, exported verbatim to telemetry.
    public var reason: String
    /// Creates a candidate plan; the engine always enforces app limits.
    public init(itemsAhead: Int, itemsBehind: Int = 0, bytesPerItem: Int, secondsPerItem: Double? = nil,
                keepReadyPlayer: Bool = true, startingBitRate: Double = 0, concurrency: Int = 1,
                paused: Bool = false, startAfterSeconds: Double = 0, reason: String) {
        self.itemsAhead = itemsAhead; self.itemsBehind = itemsBehind; self.bytesPerItem = bytesPerItem
        self.secondsPerItem = secondsPerItem; self.keepReadyPlayer = keepReadyPlayer
        self.startingBitRate = startingBitRate; self.concurrency = concurrency; self.paused = paused
        self.startAfterSeconds = startAfterSeconds; self.reason = reason
    }
    /// Enforced by the engine for every provider, including custom partner policies.
    public func clamped(to c: HMPlayerConfiguration) -> Self {
        var p = self
        p.itemsAhead = max(0, min(8, c.prefetch.ahead, p.itemsAhead))
        p.itemsBehind = max(0, min(8, c.prefetch.behind, p.itemsBehind))
        let count = p.itemsAhead + p.itemsBehind
        p.bytesPerItem = max(0, min(HMPrefetchPolicy.maximumBytesPerItem, c.prefetch.bytesPerItem,
                                   count > 0 ? max(0, c.cacheCapacityBytes) / count : 0, p.bytesPerItem))
        if let limit = c.prefetch.secondsPerItem { p.secondsPerItem = min(nonnegative(limit), nonnegative(p.secondsPerItem ?? limit)) }
        else if let seconds = p.secondsPerItem { p.secondsPerItem = nonnegative(seconds) }
        p.keepReadyPlayer = p.keepReadyPlayer && c.poolSize > 1 &&
            (c.strategy == .S2 ? c.prefetch.ahead > 0 || c.prefetch.behind > 0 : c.strategy == .S3 && c.prefetch.ahead > 0)
        p.startingBitRate = nonnegative(p.startingBitRate)
        for cap in c.adaptive ? [c.startupPeakBitRate, c.steadyPeakBitRate] : [c.startupPeakBitRate] where cap.isFinite && cap > 0 {
            p.startingBitRate = p.startingBitRate > 0 ? min(p.startingBitRate, cap) : cap
        }
        p.concurrency = max(0, min(4, c.maxPrefetchConcurrency, p.concurrency))
        p.startAfterSeconds = nonnegative(p.startAfterSeconds)
        if p.paused { p.concurrency = 0; p.keepReadyPlayer = false }
        return p
    }
    var windowOffsets: [Int] {
        let distance = max(itemsAhead, itemsBehind)
        guard distance > 0 else { return [] }
        return (1...distance).flatMap { d in
            (d <= itemsAhead ? [d] : []) + (d <= itemsBehind ? [-d] : [])
        }
    }
    var workIdentity: String {
        var copy = self; copy.reason = ""
        return json(copy)
    }
}

/// Replaceable pure policy. The engine supplies EWMA measurements and clamps its result.
public protocol HMPrefetchPolicyProviding: Sendable {
    /// Returns a candidate plan for the measured state and app limits.
    func decide(_ inputs: HMPrefetchInputs, configuration: HMPlayerConfiguration) -> HMPrefetchPlan
}

/// Stateless default policy; hysteresis uses inputs.wasPaused so simulations are reproducible.
public struct HMAdaptivePrefetchPolicy: HMPrefetchPolicyProviding {
    /// Creates the stateless default provider.
    public init() {}
    /// Applies configured thresholds, readiness/dwell prioritisation and buffer hysteresis.
    public func decide(_ i: HMPrefetchInputs, configuration c: HMPlayerConfiguration) -> HMPrefetchPlan {
        let t = c.adaptiveThresholds
        var p = HMPrefetchPlan(itemsAhead: c.prefetch.ahead, itemsBehind: c.prefetch.behind,
            bytesPerItem: c.prefetch.bytesPerItem, secondsPerItem: c.prefetch.secondsPerItem,
            startingBitRate: c.startupPeakBitRate, concurrency: c.maxPrefetchConcurrency, reason: "fixed")
        guard c.adaptive else { return p.clamped(to: c) }
        let slow = i.throughputBytesPerSecond.map { $0 < nonnegative(t.slowBytesPerSecond) } == true ||
            i.latencySeconds.map { $0 > nonnegative(t.highLatencySeconds) } == true
        let fast = !slow && i.throughputBytesPerSecond.map { $0 >= max(nonnegative(t.slowBytesPerSecond), nonnegative(t.fastBytesPerSecond)) } == true
        var fraction = slow ? unit(t.slowBudgetFraction) : fast ? 1 : unit(t.mediumBudgetFraction)
        p.itemsAhead = slow ? max(0, t.slowAhead) : fast ? c.prefetch.ahead : max(0, t.mediumAhead)
        p.itemsBehind = slow ? 0 : c.prefetch.behind
        p.startingBitRate = slow ? t.slowBitRate : fast ? t.fastBitRate : t.mediumBitRate
        p.concurrency = slow ? min(1, c.maxPrefetchConcurrency) : c.maxPrefetchConcurrency
        p.reason = slow ? "slow" : fast ? "fast" : "unmeasured-or-medium"
        if let dwell = i.dwellSeconds, dwell <= nonnegative(t.bingeDwellSeconds),
           let hit = i.readyHitRate, hit < unit(t.lowHitRate) {
            p.itemsAhead = min(2, c.prefetch.ahead); p.itemsBehind = 0
            fraction = min(1, fraction * max(1, nonnegative(t.bingeBudgetMultiplier)))
            p.reason += "+binge-misses"
        } else if let dwell = i.dwellSeconds, dwell >= nonnegative(t.longDwellSeconds) {
            fraction = min(1, fraction * max(1, nonnegative(t.longDwellBudgetMultiplier)))
            p.startAfterSeconds = min(nonnegative(t.maximumDelaySeconds), dwell * unit(t.longDwellDelayFraction))
            p.reason += "+long-dwell"
        }
        p.bytesPerItem = Int(Double(max(0, min(HMPrefetchPolicy.maximumBytesPerItem, c.prefetch.bytesPerItem))) * fraction)
        if let seconds = c.prefetch.secondsPerItem { p.secondsPerItem = nonnegative(seconds) * fraction }
        let safety = max(nonnegative(t.safetyBufferSeconds), nonnegative(c.prefetch.startThreshold) * 0.5)
        let recovery = max(safety, nonnegative(t.recoveryBufferSeconds), nonnegative(c.prefetch.startThreshold))
        let threshold = i.wasPaused ? recovery : safety
        let complete = i.remainingSeconds.map { $0.isFinite && $0 > 0 && i.bufferedAheadSeconds >= $0 - 0.1 } == true
        p.paused = i.isStalling || !i.bufferedAheadSeconds.isFinite || (!complete && i.bufferedAheadSeconds < threshold)
        if p.paused { p.reason += i.isStalling ? "+stall" : "+buffer-safety" }
        return p.clamped(to: c)
    }
}

func nonnegative(_ x: Double) -> Double { x.isFinite ? max(0, x) : 0 }
private func unit(_ x: Double) -> Double { min(1, nonnegative(x)) }
func json<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return String(data: (try? encoder.encode(value)) ?? Data(), encoding: .utf8) ?? "{}"
}

/// Only actual transfers and page arrivals update these EWMAs; cache reads never inflate throughput.
struct HMPrefetchMeasurements {
    private(set) var throughput: Double?
    private(set) var latency: Double?
    private(set) var hitRate: Double?
    private(set) var dwell: Double?
    private func smoothed(_ previous: Double?, _ sample: Double, alpha: Double) -> Double {
        let a = min(1, nonnegative(alpha))
        return previous.map { $0 + a * (sample - $0) } ?? sample
    }
    mutating func transfer(bytes: Double, seconds: Double, ttfb: Double?, alpha: Double) {
        if bytes > 0, seconds > 0, (bytes / seconds).isFinite { throughput = smoothed(throughput, bytes / seconds, alpha: alpha) }
        if let ttfb, ttfb >= 0, ttfb.isFinite { latency = smoothed(latency, ttfb, alpha: alpha) }
    }
    mutating func arrival(hit: Bool, dwell seconds: Double, alpha: Double) {
        hitRate = smoothed(hitRate, hit ? 1 : 0, alpha: alpha)
        if seconds > 0, seconds.isFinite { dwell = smoothed(dwell, seconds, alpha: alpha) }
    }
}
