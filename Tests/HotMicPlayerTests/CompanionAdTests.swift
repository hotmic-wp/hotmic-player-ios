#if canImport(UIKit) && !os(watchOS)
import AVFoundation
import Foundation
import Network
import SwiftUI
import Testing
import UIKit
@_spi(Benchmark) @testable import HotMicPlayer

/// The companion ad: decided in the pre-roll slot, armed on watched time, pinned in a player-level
/// band across items, with its own audio hold. One test per behaviour-rule group.
@Suite("Companion ads", .serialized) @MainActor
struct CompanionAdTests {
    final class Provider: HMAdBreakProvider {
        var calls: [String] = []
        let decide: (HMMediaItem) async throws -> HMAdBreak
        init(_ decide: @escaping (HMMediaItem) async throws -> HMAdBreak) { self.decide = decide }
        func adBreak(for item: HMMediaItem) async throws -> HMAdBreak { calls.append(item.id); return try await decide(item) }
    }
    final class Sink: HMAnalyticsSink {
        let sinkName = "companion-test"
        var events: [HMPlaybackEvent] = []
        func handle(_ event: HMPlaybackEvent, item: HMMediaItem) { events.append(event) }
        var outcomes: [String] { events.filter { $0.kind == .adBreakEnded }.map { $0.properties["outcome"] ?? "" } }
        var companionStates: [String] { events.filter { $0.kind == .companionStateChanged }.map { $0.properties["state"] ?? "" } }
        var companionEnds: [(outcome: String, reason: String?)] {
            events.filter { $0.kind == .companionEnded }.map { ($0.properties["outcome"] ?? "", $0.properties["reason"]) }
        }
        var prefetch: [String] { events.filter { $0.kind == .adPrefetchChanged }.map { $0.properties["paused"] ?? "" } }
    }
    private func wait(_ seconds: TimeInterval = 5, _ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(predicate())
    }
    private func makePlayer(sink: Sink, poolSize: Int = 2, configure: (inout HMPlayerConfiguration) -> Void = { _ in }) -> HMPlayer {
        var configuration = HMPlayerConfiguration(poolSize: poolSize, managesAudioSession: false)
        configure(&configuration)
        let player = HMPlayer(configuration: configuration, analytics: HMAnalyticsHub(sinks: [sink]))
        player.attachFeed() // A feed surface is attached: the band can be presented.
        return player
    }
    /// Tears the player down, which finishes the stream, and returns its companion events in order.
    private func companionEvents(of player: HMPlayer, in stream: AsyncStream<HMPlayerEvent>) async -> [HMPlayerEvent] {
        player.teardown()
        var collected: [HMPlayerEvent] = []
        for await event in stream {
            switch event {
            case .companionStateChanged, .companionEnded: collected.append(event)
            default: break
            }
        }
        return collected
    }
    private func tick(_ time: TimeInterval, live: Bool = false) -> HMPlaybackSnapshot {
        var snapshot = HMPlaybackSnapshot()
        snapshot.state = .playing; snapshot.currentTime = time
        if live {
            snapshot.isLive = true; snapshot.seekableStart = time - 55; snapshot.duration = time + 5
        } else {
            snapshot.duration = 20
        }
        return snapshot
    }

    @Test("Rules 1-3: a companion decision ends the visit as companion, a second one is declined and an accepted pre-roll cancels it")
    func armingAndExclusivity() async throws {
        let url = try await PlayerNativeReviewTests().videoFixture(rotated: false, duration: 20)
        defer { try? FileManager.default.removeItem(at: url) }
        try await PlayerNativeReviewTests().prepareNativePlayback(url: url)
        let creative = HMMediaItem(id: "creative", url: url)
        var starts = 0, stops: [HMAdOutcome] = []
        let provider = Provider { item in
            switch item.id {
            case "one": return .companion(.media(creative, clickThroughURL: URL(string: "https://example.com/offer")))
            case "two": return .companion(.hostRendered(HMHostAdBreak(start: { _ in starts += 1 }, stop: { stops.append($0) })))
            default: return .preRoll(HMMediaItem(id: "pre-roll", url: url))
            }
        }
        let sink = Sink()
        let player = makePlayer(sink: sink)
        let stream = player.events
        player.adBreakProvider = provider
        let items = ["one", "two", "three"].map { HMMediaItem(id: $0, url: url) }
        player.replaceAll(items)
        try await wait { player.companionState == .armed }
        #expect(player.adState == .finished && sink.outcomes == ["companion"])
        let countdown = try #require(player.companionCountdown)
        #expect(countdown.remaining > 9.5 && countdown.remaining <= 10) // Nothing before arming counts.
        #expect(countdown.countdownLength == player.configuration.companionTrigger.countdown)
        #expect(player.companionProgress == HMAdProgress() && player.isCompanionMuted)
        // Content activates exactly as after no fill.
        try await wait { player.currentNode?.isActive == true && sink.events.contains { $0.kind == .viewStart } }
        let start = try #require(sink.events.last { $0.kind == .viewStart })
        #expect(start.properties["after_ad"] == "false" && start.properties["ad_outcome"] == nil)
        // Rule 2: a second companion while one is armed is declined without starting; the first is untouched.
        player.next()
        try await wait { sink.outcomes.count == 2 }
        #expect(sink.outcomes == ["companion", "cancelled"] && starts == 0 && stops == [.cancelled])
        #expect(sink.events.last { $0.kind == .adBreakEnded }?.properties["reason"] == "companionActive")
        #expect(player.companionState == .armed && player.companionCountdown != nil)
        try await wait { player.currentNode?.isActive == true }
        // Rule 3: an accepted pre-roll cancels the companion before it starts.
        player.next()
        try await wait { player.companionState == .none }
        #expect(sink.companionEnds.map(\.outcome) == ["cancelled"] && sink.companionEnds.first?.reason == "preRoll")
        #expect(player.adState.isActive) // The pre-roll itself proceeds as before.
        player.skipAd()
        try await wait { player.adState == .finished }
        #expect(sink.outcomes == ["companion", "cancelled", "skipped"])
        #expect(sink.companionStates == ["armed", "none"])
        let events = await companionEvents(of: player, in: stream)
        #expect(events == [
            .companionStateChanged(item: items[0], state: .armed),
            .companionStateChanged(item: items[0], state: .none),
            .companionEnded(item: items[0], outcome: .cancelled),
        ])
    }

    @Test("Rule 4: swipes, navigation and playlist edits keep a companion; dismissal and teardown end it as cancelled")
    func survivesNavigationAndEdits() async throws {
        let url = try await PlayerNativeReviewTests().videoFixture(rotated: false, duration: 20)
        defer { try? FileManager.default.removeItem(at: url) }
        let creative = HMMediaItem(id: "creative", url: url)
        let provider = Provider { item in item.id == "one" ? .companion(.media(creative)) : .none }
        let sink = Sink()
        let player = makePlayer(sink: sink, poolSize: 3)
        player.adBreakProvider = provider
        let items = ["one", "two", "three", "four"].map { HMMediaItem(id: $0, url: url) }
        player.replaceAll(items)
        try await wait { player.companionState == .armed }
        player.next(); player.previous(); player.jump(toID: "three")
        try await wait { player.currentItem?.id == "three" && player.adState == .finished }
        #expect(player.companionState == .armed && sink.companionEnds.isEmpty)
        var metadata = items; metadata[2] = HMMediaItem(id: "three", url: url, title: "retitled")
        player.replaceAll(metadata, startAt: 2)
        player.reconcile(metadata.reversed())
        player.append([HMMediaItem(id: "five", url: url)])
        player.remove(ids: ["four"])
        player.commitPage(toID: "two", requestedAt: ProcessInfo.processInfo.systemUptime)
        try await wait { player.currentItem?.id == "two" && player.adState == .finished }
        #expect(player.companionState == .armed && sink.companionEnds.isEmpty)
        #expect(sink.outcomes.allSatisfy { ["companion", "noFill", "cancelled"].contains($0) }) // Revisits are declined, never started.
        player.dismissCompanion()
        #expect(player.companionState == .none && player.companionCountdown == nil)
        #expect(sink.companionEnds.map(\.outcome) == ["cancelled"] && sink.companionEnds.last?.reason == "dismissed")
        player.dismissCompanion() // Inert without a companion.
        #expect(sink.companionEnds.count == 1)
        // Returning to the arming item consults again and arms a new companion; teardown cancels it.
        player.jump(toID: "one")
        try await wait { player.companionState == .armed }
        player.teardown()
        #expect(player.companionState == .none)
        #expect(sink.companionEnds.map(\.outcome) == ["cancelled", "cancelled"] && sink.companionEnds.last?.reason == "teardown")
    }

    @Test("Rule 5: watched time sums positive playhead progress while content advances; seeks, loops, stalls and a live window add nothing")
    func watchedTimeClock() {
        var clock = HMWatchedTimeClock()
        #expect(clock.watched == 0 && clock.rate == 0)
        #expect(clock.record(tick(10), advancing: true, at: 100) == 0) // The first tick only sets the baseline.
        for step in 1...5 { #expect(clock.record(tick(10 + Double(step) * 0.1), advancing: true, at: 100 + Double(step) * 0.1) > 0.099) }
        #expect(abs(clock.watched - 0.5) < 0.001 && clock.rate == 1)
        // A loop jumps backwards: nothing is added and the next tick re-baselines.
        #expect(clock.record(tick(0.2), advancing: true, at: 100.6) == 0)
        #expect(clock.record(tick(0.3), advancing: true, at: 100.7) > 0.099)
        // A forward seek within one tick is bounded by elapsed wall time plus tolerance.
        let bounded = clock.record(tick(30), advancing: true, at: 100.8)
        #expect(bounded <= 0.1 + HMWatchedTimeClock.tolerance + 0.001)
        // A reported seek drops the baseline, so the landing tick adds nothing at all.
        clock.discontinuity()
        #expect(clock.record(tick(45), advancing: true, at: 100.9) == 0)
        // A stall or pause: the tick that is not advancing adds nothing and reports a zero rate.
        #expect(clock.record(tick(45), advancing: false, at: 101.5) == 0 && clock.rate == 0)
        #expect(clock.record(tick(45.1), advancing: true, at: 101.6) == 0) // Re-baseline after the stall.
        let before = clock.watched
        // Live-shaped input: a sliding window and a growing duration change nothing; only progress counts.
        var live = HMWatchedTimeClock()
        var expected = 0.0
        for step in 0...20 {
            let time = 1255 + Double(step) * 0.1
            let gained = live.record(tick(time, live: true), advancing: true, at: 200 + Double(step) * 0.1)
            if step > 0 { expected += 0.1 }
            #expect(abs(gained - (step > 0 ? 0.1 : 0)) < 0.001)
        }
        #expect(abs(live.watched - expected) < 0.001 && live.rate == 1)
        #expect(clock.watched == before)
        #expect(clock.isStale(at: 101.6) == false)
        #expect(live.isStale(at: 210) && !HMWatchedTimeClock().isStale(at: 0))
    }

    @Test("Rules 5-8: item scope restarts on item changes, the countdown advances only while presentable, and samples carry the rate")
    func scopesAndPresentability() async throws {
        let url = try await PlayerNativeReviewTests().videoFixture(rotated: false, duration: 20)
        defer { try? FileManager.default.removeItem(at: url) }
        let creative = HMMediaItem(id: "creative", url: url)
        let trigger = HMCompanionTrigger(watchedTime: 1, countdown: 0.5, scope: .item)
        let provider = Provider { item in item.id == "one" ? .companion(.media(creative, trigger: trigger)) : .none }
        let sink = Sink()
        let player = makePlayer(sink: sink)
        player.adBreakProvider = provider
        let items = ["one", "two"].map { HMMediaItem(id: $0, url: url) }
        player.replaceAll(items)
        try await wait { player.companionState == .armed && player.currentNode?.isActive == true }
        player.pause() // Synthetic ticks only from here on.
        let base = ProcessInfo.processInfo.systemUptime
        func advance(_ steps: Int, from start: Int) {
            for step in start..<(start + steps) {
                player.recordContentTick(tick(Double(step) * 0.1), advancing: true, at: base + Double(step) * 0.1)
            }
        }
        advance(1, from: 0) // Baseline.
        advance(4, from: 1) // 0.4 s watched.
        #expect(player.companionState == .armed)
        var sample = try #require(player.companionCountdown)
        #expect(abs(sample.remaining - 0.6) < 0.001 && sample.rate == 1 && sample.countdownLength == 0.5)
        #expect(abs(sample.estimatedRemaining(at: sample.sampledAt + 0.25) - 0.35) < 0.001)
        #expect(sample.estimatedRemaining(at: sample.sampledAt + 10) == 0)
        advance(1, from: 5) // 0.5 s watched: the countdown begins because the band can be presented.
        #expect(player.companionState == .countdown)
        #expect(player.companionNode != nil) // The creative warms when the countdown begins.
        // Rule 6/7: not presentable freezes the countdown; the sample reports a zero rate.
        player.isPictureInPictureActive = true
        sample = try #require(player.companionCountdown)
        #expect(sample.rate == 0 && abs(sample.remaining - 0.5) < 0.001)
        advance(3, from: 6)
        #expect(abs((player.companionCountdown?.remaining ?? -1) - 0.5) < 0.001 && player.companionState == .countdown)
        player.isPictureInPictureActive = false
        advance(1, from: 9) // Re-baseline after the freeze.
        advance(1, from: 10)
        #expect(abs((player.companionCountdown?.remaining ?? -1) - 0.4) < 0.001)
        // Cover keys are independent: clearing one never clears another.
        player.setCompanionCovered(true, by: "registration")
        player.setCompanionCovered(true, by: "comments")
        player.setCompanionCovered(false, by: "registration")
        #expect(player.isCompanionCovered && player.companionCountdown?.rate == 0)
        advance(2, from: 11)
        #expect(abs((player.companionCountdown?.remaining ?? -1) - 0.4) < 0.001)
        player.setCompanionCovered(false, by: "comments")
        #expect(!player.isCompanionCovered)
        // Rule 5: item scope restarts on an item change, and the companion stays armed.
        player.next()
        try await wait { player.currentItem?.id == "two" && player.adState == .finished }
        #expect(player.companionState == .armed)
        #expect(abs((player.companionCountdown?.remaining ?? -1) - 1) < 0.001)
        player.previous()
        try await wait { player.currentItem?.id == "one" && player.adState == .finished }
        #expect(sink.outcomes == ["companion", "noFill", "cancelled"] && player.companionState == .armed) // Revisiting is declined: still armed.
        #expect(sink.events.last { $0.kind == .adBreakEnded }?.properties["reason"] == "companionActive")
        advance(1, from: 20)
        advance(10, from: 21) // 1.0 s watched on this item: present.
        try await wait { player.companionState == .playing(kind: .player) }
        #expect(player.companionCountdown == nil && player.isCompanionMuted)
        #expect(sink.companionStates == ["armed", "countdown", "armed", "countdown", "playing"])
        #expect(sink.events.last { $0.kind == .companionStateChanged }?.properties["kind"] == "player")
        try await wait { player.companionProgress.duration > 0 }
        player.skipCompanion()
        #expect(player.companionState == .none && player.companionNode == nil)
        #expect(sink.companionEnds.map(\.outcome) == ["skipped"])
        player.teardown()
    }

    @Test("Rules 9-10: host start runs at presentation, deadlines end a stuck companion, and stop runs once", arguments: ["host-complete", "host-idle", "host-cap", "url-startup", "url-failed"])
    func creativeTimingAndDeadlines(mode: String) async throws {
        let url = try await PlayerNativeReviewTests().videoFixture(rotated: false, duration: 20)
        defer { try? FileManager.default.removeItem(at: url) }
        var contexts: [HMHostAdContext] = [], stops: [HMAdOutcome] = []
        let host = HMHostAdBreak(start: { contexts.append($0) }, stop: { stops.append($0) })
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hotmic-missing-\(UUID()).mp4")
        // A hanging origin accepts the request and never answers, so the creative stalls at startup instead of
        // racing the deadline: a warmed engine can show a local file's first frame inside 0.1 s.
        let origin: PlayerNativeReviewTests.PrefixOrigin? = try mode == "url-startup" ? PlayerNativeReviewTests.PrefixOrigin() : nil
        defer { origin?.stop() }
        var stalling = missing
        if let origin {
            // NWListener can publish .any (rawValue 0) before it is ready.
            let deadline = Date().addingTimeInterval(5)
            while (origin.listener.port?.rawValue ?? 0) == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            let port = try #require(origin.listener.port)
            stalling = URL(string: "http://127.0.0.1:\(port.rawValue)/companion.mp4")!
        }
        let stalled = stalling
        // A zero countdown warms the creative only at presentation, so the startup deadline runs on a cold node.
        let trigger = HMCompanionTrigger(watchedTime: 0.3, countdown: mode == "url-startup" ? 0 : 0.1)
        let provider = Provider { item in
            guard item.id == "one" else { return .none }
            switch mode {
            case "url-startup": return .companion(.media(HMMediaItem(id: "creative", url: stalled), trigger: trigger))
            case "url-failed": return .companion(.media(HMMediaItem(id: "creative", url: missing), trigger: trigger))
            default: return .companion(.hostRendered(host, trigger: trigger))
            }
        }
        let sink = Sink()
        let player = makePlayer(sink: sink) { c in
            c.adLoadTimeout = mode == "url-startup" ? 0.1 : 5
            c.adNoProgressTimeout = mode == "host-idle" ? 0.3 : 10
            c.adBreakMaxDuration = mode == "host-cap" ? 0.5 : 10
        }
        player.adBreakProvider = provider
        player.setCompanionBandMounted(true) // The band surface is in a window, so start runs at presentation.
        player.replaceAll([HMMediaItem(id: "one", url: url), HMMediaItem(id: "two", url: url)])
        try await wait { player.companionState == .armed }
        #expect(contexts.isEmpty) // Never before presentation.
        if mode.hasPrefix("url") {
            try await wait { player.companionState == .none }
            #expect(sink.companionEnds.map(\.outcome) == [mode == "url-startup" ? "timedOut" : "failed"] && player.companionNode == nil)
            #expect(sink.companionStates == ["armed", "countdown", "none"])
            #expect(player.currentNode?.isActive == true && player.wantsPlayback) // Content was never held.
            player.teardown()
            return
        }
        try await wait { player.companionState == .playing(kind: .host) && contexts.count == 1 }
        let context = try #require(contexts.first)
        #expect(context.isMuted && context.isPlaybackAllowed)
        #expect(contexts[0].container.backgroundColor == .black)
        switch mode {
        case "host-complete":
            context.updateProgress(HMAdProgress(elapsed: 2, duration: 30))
            #expect(player.companionProgress == HMAdProgress(elapsed: 2, duration: 30))
            context.complete(); context.fail(); context.skip() // One-shot: later calls are inert.
            #expect(player.companionState == .none && stops == [.completed])
            #expect(sink.companionEnds.map(\.outcome) == ["completed"] && !context.isPlaybackAllowed)
            #expect(player.companionProgress == HMAdProgress())
        case "host-idle":
            try await wait { player.companionState == .none }
            #expect(stops == [.timedOut] && sink.companionEnds.map(\.outcome) == ["timedOut"])
        default:
            // Progress keeps the no-progress watchdog quiet; the wall cap still ends it.
            let reporting = Task { @MainActor in
                var elapsed = 0.0
                while !Task.isCancelled { elapsed += 0.05; context.updateProgress(HMAdProgress(elapsed: elapsed, duration: 30)); try? await Task.sleep(for: .milliseconds(50)) }
            }
            try await wait { player.companionState == .none }
            reporting.cancel()
            #expect(stops == [.timedOut] && sink.companionEnds.map(\.outcome) == ["timedOut"])
        }
        #expect(contexts.count == 1 && player.companionHostContext == nil)
        player.teardown()
        #expect(stops.count == 1) // Teardown after the end never stops the adapter again.
    }

    @Test("Rules 16-18: unmuting holds content, re-muting, play, navigation and the end release it, and a viewer pause wins")
    func audioHold() async throws {
        let url = try await PlayerNativeReviewTests().videoFixture(rotated: false, duration: 20)
        defer { try? FileManager.default.removeItem(at: url) }
        let creative = HMMediaItem(id: "creative", url: url)
        let trigger = HMCompanionTrigger(watchedTime: 0.3, countdown: 0)
        let provider = Provider { item in item.id == "one" ? .companion(.media(creative, trigger: trigger)) : .none }
        let sink = Sink()
        let player = makePlayer(sink: sink)
        player.adBreakProvider = provider
        let items = ["one", "two"].map { HMMediaItem(id: $0, url: url) }
        player.replaceAll(items)
        try await wait { player.companionState == .playing(kind: .player) }
        let node = try #require(player.companionNode)
        #expect(player.isCompanionMuted && node.player.isMuted && !player.isMuted)
        let content = try #require(player.currentNode)
        try await wait { content.snapshot.state == .playing }
        // Unmute: the creative plays with sound and content is held, not viewer-paused.
        player.isCompanionMuted = false
        #expect(!node.player.isMuted && player.wantsPlayback && !player.isMuted)
        try await wait { player.snapshot.state == .paused }
        #expect(player.isMuted == false)
        // Re-mute releases the hold.
        player.isCompanionMuted = true
        #expect(node.player.isMuted)
        try await wait { player.snapshot.state == .playing }
        // Tapping the video while held resumes content and re-mutes the companion.
        player.isCompanionMuted = false
        try await wait { player.snapshot.state == .paused }
        player.togglePlayPause()
        #expect(player.isCompanionMuted && player.wantsPlayback)
        try await wait { player.snapshot.state == .playing }
        // A viewer pause during the hold wins: releasing leaves content paused.
        player.isCompanionMuted = false
        try await wait { player.snapshot.state == .paused }
        player.pause()
        player.isCompanionMuted = true
        try await Task.sleep(for: .milliseconds(200))
        #expect(player.snapshot.state == .paused && !player.wantsPlayback)
        player.play()
        try await wait { player.snapshot.state == .playing }
        // Navigation re-mutes the companion and the next item plays.
        player.isCompanionMuted = false
        try await wait { player.snapshot.state == .paused }
        player.next()
        #expect(player.isCompanionMuted)
        try await wait { player.currentItem?.id == "two" && player.snapshot.state == .playing }
        #expect(player.companionState == .playing(kind: .player)) // Pinned across the swipe.
        // The hold ends with the companion.
        player.isCompanionMuted = false
        try await wait { player.snapshot.state == .paused }
        player.dismissCompanion()
        #expect(player.isCompanionMuted && player.companionState == .none)
        try await wait { player.snapshot.state == .playing }
        #expect(!player.isMuted) // Content mute is never touched by the companion.
        player.teardown()
    }

    @Test("Rule 19: a playing companion pauses while not presentable and resumes when presentable again")
    func coverAndSuppressionWhilePlaying() async throws {
        let url = try await PlayerNativeReviewTests().videoFixture(rotated: false, duration: 20)
        defer { try? FileManager.default.removeItem(at: url) }
        var context: HMHostAdContext?, permissions: [Bool] = []
        let host = HMHostAdBreak(start: { context = $0; $0.onPlaybackAllowedChange = { permissions.append($0) } }, stop: { _ in })
        let trigger = HMCompanionTrigger(watchedTime: 0.3, countdown: 0)
        let provider = Provider { item in item.id == "one" ? .companion(.hostRendered(host, trigger: trigger)) : .none }
        let sink = Sink()
        let player = makePlayer(sink: sink)
        player.adBreakProvider = provider
        player.setCompanionBandMounted(true)
        player.replaceAll([HMMediaItem(id: "one", url: url)])
        try await wait { player.companionState == .playing(kind: .host) && context != nil }
        #expect(context?.isPlaybackAllowed == true)
        player.isPictureInPictureActive = true
        #expect(context?.isPlaybackAllowed == false)
        player.isPictureInPictureActive = false
        #expect(context?.isPlaybackAllowed == true)
        player.externalPlaybackOverride = true
        #expect(context?.isPlaybackAllowed == false)
        player.externalPlaybackOverride = nil
        player.setCompanionCovered(true, by: "comments")
        #expect(context?.isPlaybackAllowed == false)
        player.setCompanionCovered(false, by: "comments")
        player.enterFullscreen()
        #expect(context?.isPlaybackAllowed == false)
        player.exitFullscreen()
        player.isFeedVisible = false
        #expect(context?.isPlaybackAllowed == false)
        player.isFeedVisible = true
        #expect(context?.isPlaybackAllowed == true)
        #expect(permissions == [false, true, false, true, false, true, false, true, false, true])
        #expect(player.companionState == .playing(kind: .host)) // Pinned throughout.
        player.teardown()
    }

    @Test("Rule 21: a companion never pauses bulk prefetch or evicts the next content head")
    func noPrefetchGate() async throws {
        let url = try await PlayerNativeReviewTests().videoFixture(rotated: false, duration: 20)
        defer { try? FileManager.default.removeItem(at: url) }
        let creative = HMMediaItem(id: "creative", url: url)
        let trigger = HMCompanionTrigger(watchedTime: 0.3, countdown: 0.1)
        let provider = Provider { item in item.id == "one" ? .companion(.media(creative, trigger: trigger)) : .none }
        let sink = Sink()
        let player = makePlayer(sink: sink)
        player.adBreakProvider = provider
        let items = ["one", "two", "three"].map { HMMediaItem(id: $0, url: url) }
        player.replaceAll(items)
        try await wait { player.companionState == .playing(kind: .player) && player.node(for: items[1]) != nil }
        try await Task.sleep(for: .milliseconds(300))
        #expect(sink.prefetch == ["true", "false"]) // Only the decision pauses and resumes bulk work.
        #expect(player.node(for: items[1]) != nil && player.preparedItemCount == 2)
        #expect(player.prefetchPlan?.paused != true && !player.isAdSwipeBlocked)
        player.teardown()
    }

    @Test("Rule 11: the band is full width, aspect-sized, capped at a third of the inset viewport, docked above host chrome, and slides instantly under Reduce Motion")
    func bandMetrics() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let band = HMCompanionBandMetrics(bounds: bounds, bottomInset: 54 + 34, aspectRatio: 16.0 / 9)
        #expect(abs(band.frame.height - 390 * 9 / 16) < 0.001 && band.frame.width == 390 && band.frame.minX == 0)
        #expect(abs(band.frame.maxY - (844 - 88)) < 0.001 && band.dock == 88)
        let capped = HMCompanionBandMetrics(bounds: bounds, bottomInset: 88, aspectRatio: 1)
        #expect(abs(capped.frame.height - (844 - 88) / 3) < 0.001)
        let invalid = HMCompanionBandMetrics(bounds: bounds, bottomInset: .nan, aspectRatio: .nan)
        #expect(abs(invalid.frame.height - 390 * 9 / 16) < 0.001 && invalid.dock == 0)
        // Rule 12: the band squeezes every page from the bottom and intersects a host target, so a sheet sits above it.
        #expect(band.squeeze(intersecting: nil) == CGRect(x: 0, y: 0, width: 390, height: band.frame.minY))
        let sheet = CGRect(x: 0, y: 0, width: 390, height: 300)
        #expect(band.squeeze(intersecting: sheet) == sheet)
        #expect(HMCompanionBandMetrics.slideAnimation(reduceMotion: true) == nil)
        #expect(HMCompanionBandMetrics.slideAnimation(reduceMotion: false) != nil)
        var snapshot = HMPlaybackSnapshot()
        #expect(snapshot.companionFrame == nil)
        snapshot.companionFrame = band.frame
        #expect(snapshot.companionFrame == band.frame)
    }

    @Test("Section 2: triggers sanitize, the state knows when it is presented, and the benchmark record keeps the trigger")
    func contractValues() {
        let sanitized = HMCompanionTrigger(watchedTime: -1, countdown: .nan, scope: .item).sanitized
        #expect(sanitized == HMCompanionTrigger(watchedTime: 10, countdown: 5, scope: .item))
        #expect(HMCompanionTrigger(watchedTime: 3, countdown: 8).sanitized.countdown == 3) // Clamped to 0...watchedTime.
        #expect(HMCompanionTrigger() == HMCompanionTrigger(watchedTime: 10, countdown: 5, scope: .session))
        #expect(HMCompanionState.playing(kind: .host).isPresented && !HMCompanionState.countdown.isPresented && !HMCompanionState.armed.isPresented && !HMCompanionState.none.isPresented)
        #expect(HMAdOutcome.companion.rawValue == "companion" && HMWatchedTimeScope.item.rawValue == "item")
        #expect(HMPlaybackEvent.Kind.companionStateChanged.rawValue == "companionStateChanged")
        #expect(HMPlaybackEvent.Kind(rawValue: "companionEnded") == .companionEnded)
        let media = HMCompanionBreak.media(HMMediaItem(id: "ad", url: URL(string: "https://example.com/ad.mp4")!), clickThroughURL: URL(string: "https://example.com"), aspectRatio: 4 / 3)
        #expect(media.kind == .player && media.aspectRatio == 4 / 3 && media.trigger == nil && media.clickThroughURL != nil)
        let host = HMCompanionBreak.hostRendered(HMHostAdBreak(start: { _ in }), trigger: HMCompanionTrigger(watchedTime: 20, countdown: 3))
        #expect(host.kind == .host && host.aspectRatio == 16 / 9 && host.trigger?.watchedTime == 20)
        var configuration = HMPlayerConfiguration()
        #expect(configuration.companionTrigger == HMCompanionTrigger())
        configuration.companionTrigger = HMCompanionTrigger(watchedTime: 20, countdown: 3, scope: .item)
        let restored = configuration.benchmarkRecord.configuration
        #expect(restored.companionTrigger == configuration.companionTrigger)
        #expect(configuration.fingerprint.contains("\"companionScope\":\"item\""))
    }
}
#endif
