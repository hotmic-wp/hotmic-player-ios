import Testing
import Foundation
@_spi(Benchmark) @testable import HotMicPlayer

@Suite("Adaptive prefetch")
struct AdaptivePrefetchTests {
    struct Row: Sendable {
        let name: String
        var inputs = HMPrefetchInputs(bufferedAheadSeconds: 6)
        var configuration = HMPlayerConfiguration()
        let ahead: Int
        let behind: Int
        let bytes: Int
        let bitrate: Double
        var paused = false
        var ready = true
        var concurrency = 1
        var delay = 0.0
        let reason: String
    }
    static var rows: [Row] {
        var slow = HMPrefetchInputs(throughputBytesPerSecond: 250_000, bufferedAheadSeconds: 6)
        var fast = HMPrefetchInputs(throughputBytesPerSecond: 4_000_000, bufferedAheadSeconds: 6)
        var fixed = HMPlayerConfiguration(adaptive: false)
        var cap = HMPlayerConfiguration(poolSize: 1, prefetch: .init(ahead: 1, behind: 0, bytesPerItem: 100_000, secondsPerItem: 2), cacheCapacityBytes: 50_000, startupPeakBitRate: 300_000)
        cap.maxPrefetchConcurrency = 0
        var rows = [
            Row(name: "unknown", ahead: 3, behind: 1, bytes: 400_000, bitrate: 1_000_000, reason: "unmeasured-or-medium"),
            Row(name: "slow", inputs: slow, ahead: 2, behind: 0, bytes: 200_000, bitrate: 600_000, reason: "slow"),
            Row(name: "fast", inputs: fast, ahead: 5, behind: 1, bytes: 800_000, bitrate: 1_600_000, reason: "fast"),
            Row(name: "fixed ignores telemetry", inputs: slow, configuration: fixed, ahead: 5, behind: 1, bytes: 800_000, bitrate: 1_600_000, reason: "fixed"),
            Row(name: "app caps", inputs: fast, configuration: cap, ahead: 1, behind: 0, bytes: 50_000, bitrate: 300_000, ready: false, concurrency: 0, reason: "fast")
        ]
        fast.latencySeconds = 0.5
        rows.append(Row(name: "high latency", inputs: fast, ahead: 2, behind: 0, bytes: 200_000, bitrate: 600_000, reason: "slow"))
        slow.dwellSeconds = 1; slow.readyHitRate = 0.2
        rows.append(Row(name: "binge misses", inputs: slow, ahead: 2, behind: 0, bytes: 300_000, bitrate: 600_000, reason: "slow+binge-misses"))
        slow.dwellSeconds = 10
        rows.append(Row(name: "long dwell", inputs: slow, ahead: 2, behind: 0, bytes: 300_000, bitrate: 600_000, delay: 5, reason: "slow+long-dwell"))
        for (buffer, wasPaused, pauses) in [(1.4, false, true), (1.5, false, false), (2.9, true, true), (3.0, true, false)] {
            rows.append(Row(name: "hysteresis \(buffer)/\(wasPaused)", inputs: HMPrefetchInputs(bufferedAheadSeconds: buffer, wasPaused: wasPaused),
                ahead: 3, behind: 1, bytes: 400_000, bitrate: 1_000_000, paused: pauses, ready: !pauses,
                concurrency: pauses ? 0 : 1, reason: "unmeasured-or-medium" + (pauses ? "+buffer-safety" : "")))
        }
        rows.append(Row(name: "stall despite buffer", inputs: HMPrefetchInputs(bufferedAheadSeconds: 20, isStalling: true),
            ahead: 3, behind: 1, bytes: 400_000, bitrate: 1_000_000, paused: true, ready: false, concurrency: 0, reason: "unmeasured-or-medium+stall"))
        rows.append(Row(name: "fully buffered tail", inputs: HMPrefetchInputs(bufferedAheadSeconds: 1, remainingSeconds: 1),
            ahead: 3, behind: 1, bytes: 400_000, bitrate: 1_000_000, reason: "unmeasured-or-medium"))
        fixed = HMPlayerConfiguration(prefetch: .off)
        rows.append(Row(name: "off", inputs: fast, configuration: fixed, ahead: 0, behind: 0, bytes: 0, bitrate: 600_000, ready: false, reason: "slow"))
        return rows
    }

    @Test("Measured inputs map to bounded plans", arguments: rows)
    func decisions(_ row: Row) {
        let p = HMAdaptivePrefetchPolicy().decide(row.inputs, configuration: row.configuration)
        #expect(p.itemsAhead == row.ahead, "\(row.name)")
        #expect(p.itemsBehind == row.behind, "\(row.name)")
        #expect(p.bytesPerItem == row.bytes, "\(row.name)")
        #expect(p.startingBitRate == row.bitrate, "\(row.name)")
        #expect(p.paused == row.paused, "\(row.name)")
        #expect(p.keepReadyPlayer == row.ready, "\(row.name)")
        #expect(p.concurrency == row.concurrency, "\(row.name)")
        #expect(p.startAfterSeconds == row.delay, "\(row.name)")
        #expect(p.reason == row.reason, "\(row.name)")
        #expect(p.windowOffsets.first == (p.itemsAhead > 0 ? 1 : p.itemsBehind > 0 ? -1 : nil))
    }

    @Test("Partner plans cannot exceed budgets; EWMAs and configuration roundtrip preserve measured tuning")
    func boundaries() throws {
        let c = HMPlayerConfiguration(prefetch: .init(ahead: 2, behind: 1, bytesPerItem: 500, secondsPerItem: 2), cacheCapacityBytes: 600)
        let partner = HMPrefetchPlan(itemsAhead: Int.max, itemsBehind: Int.max, bytesPerItem: Int.max,
            secondsPerItem: 999, startingBitRate: 0, concurrency: Int.max, reason: "partner").clamped(to: c)
        #expect(partner.itemsAhead == 2 && partner.itemsBehind == 1 && partner.bytesPerItem == 200)
        #expect(partner.secondsPerItem == 2 && partner.startingBitRate == 1_600_000 && partner.concurrency == 1)
        #expect(partner.windowOffsets == [1, -1, 2])
        let negative = HMPrefetchPlan(itemsAhead: -1, itemsBehind: -2, bytesPerItem: -100, secondsPerItem: .nan,
            startingBitRate: .infinity, concurrency: -1, startAfterSeconds: .nan, reason: "invalid").clamped(to: c)
        #expect(negative.itemsAhead == 0 && negative.itemsBehind == 0 && negative.bytesPerItem == 0)
        #expect(negative.secondsPerItem == 0 && negative.startAfterSeconds == 0 && negative.concurrency == 0)
        var limits = c; limits.startupPeakBitRate = 0; limits.steadyPeakBitRate = 400_000
        #expect(partner.clamped(to: limits).startingBitRate == 400_000)
        limits.adaptive = false; limits.startupPeakBitRate = 0
        #expect(HMAdaptivePrefetchPolicy().decide(HMPrefetchInputs(), configuration: limits).startingBitRate == 0)
        let unsafe = HMAdaptivePrefetchPolicy().decide(HMPrefetchInputs(bufferedAheadSeconds: .nan), configuration: c)
        #expect(unsafe.paused)
        var m = HMPrefetchMeasurements()
        m.transfer(bytes: 1000, seconds: 1, ttfb: 0.2, alpha: 0.25)
        m.transfer(bytes: 3000, seconds: 1, ttfb: 0.6, alpha: 0.25)
        m.transfer(bytes: 0, seconds: 1, ttfb: nil, alpha: 0.25)
        m.arrival(hit: false, dwell: 1, alpha: 0.25); m.arrival(hit: true, dwell: 5, alpha: 0.25)
        #expect(m.throughput == 1500 && abs((m.latency ?? 0) - 0.3) < 0.0001)
        #expect(m.hitRate == 0.25 && m.dwell == 2)
        var tuned = c; tuned.adaptive = false; tuned.adaptiveThresholds.slowBytesPerSecond = 12345
        tuned.maxPrefetchConcurrency = 3; tuned.resolveAhead = 12
        let roundtrip = try JSONDecoder().decode(HMPlayerConfiguration.BenchmarkRecord.self,
            from: JSONEncoder().encode(tuned.benchmarkRecord)).configuration
        #expect(roundtrip.fingerprint == tuned.fingerprint)
        // Seconds are scaled as well as bytes, without ever removing an app time cap.
        let slow = HMAdaptivePrefetchPolicy().decide(HMPrefetchInputs(throughputBytesPerSecond: 100_000, bufferedAheadSeconds: 5), configuration: c)
        #expect(slow.secondsPerItem == 0.5)
    }
}
