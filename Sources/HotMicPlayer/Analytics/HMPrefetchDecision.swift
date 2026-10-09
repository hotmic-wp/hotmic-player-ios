import Foundation

// Experimental JSONL snapshots, deliberately separate from partner values.
struct HMPrefetchInputsRecord: Encodable, Sendable {
    let throughputBytesPerSecond: Double?
    let latencySeconds: Double?
    let readyHitRate: Double?
    let dwellSeconds: Double?
    let bufferedAheadSeconds: Double
    let remainingSeconds: Double?
    let isStalling: Bool
    let wasPaused: Bool
    let elapsedOnItemSeconds: Double
    let previousPlan: HMPrefetchPlanRecord?
    init(_ value: HMPrefetchInputs) {
        throughputBytesPerSecond = value.throughputBytesPerSecond
        latencySeconds = value.latencySeconds
        readyHitRate = value.readyHitRate
        dwellSeconds = value.dwellSeconds
        bufferedAheadSeconds = value.bufferedAheadSeconds
        remainingSeconds = value.remainingSeconds
        isStalling = value.isStalling
        wasPaused = value.wasPaused
        elapsedOnItemSeconds = value.elapsedOnItemSeconds
        previousPlan = value.previousPlan.map(HMPrefetchPlanRecord.init)
    }
}

struct HMPrefetchPlanRecord: Encodable, Sendable {
    let itemsAhead: Int
    let itemsBehind: Int
    let bytesPerItem: Int
    let secondsPerItem: Double?
    let keepReadyPlayer: Bool
    let startingBitRate: Double
    let concurrency: Int
    let paused: Bool
    let startAfterSeconds: Double
    let reason: String
    let speedTier: String
    init(_ value: HMPrefetchPlan) {
        itemsAhead = value.itemsAhead
        itemsBehind = value.itemsBehind
        bytesPerItem = value.bytesPerItem
        secondsPerItem = value.secondsPerItem
        keepReadyPlayer = value.keepReadyPlayer
        startingBitRate = value.startingBitRate
        concurrency = value.concurrency
        paused = value.paused
        startAfterSeconds = value.startAfterSeconds
        reason = value.reason
        speedTier = value.speedTier.rawValue
    }
}

struct HMPrefetchDecision: Sendable {
    let itemID: String
    let monotonicTime: TimeInterval
    let inputs: HMPrefetchInputs
    let plan: HMPrefetchPlan
    let policy: String
    var event: HMPlaybackEvent {
        HMPlaybackEvent(kind: .prefetchDecision, itemID: itemID, monotonicTime: monotonicTime, metrics: [
            "plan_changed": 1, "budget_bytes": Double(plan.bytesPerItem),
            "items_ahead": Double(plan.itemsAhead), "items_behind": Double(plan.itemsBehind),
            "paused": plan.paused ? 1 : 0, "concurrency": Double(plan.concurrency),
            "starting_bitrate": plan.startingBitRate, "ready_hit_rate": inputs.readyHitRate ?? -1,
            "throughput_bytes_s": inputs.throughputBytesPerSecond ?? -1, "latency_s": inputs.latencySeconds ?? -1,
            "dwell_s": inputs.dwellSeconds ?? -1, "buffered_ahead_s": inputs.bufferedAheadSeconds
        ], properties: ["inputs": json(HMPrefetchInputsRecord(inputs)), "plan": json(HMPrefetchPlanRecord(plan)),
                        "reason": plan.reason, "policy": policy])
    }
}
