#if canImport(UIKit) && !os(watchOS)
import AVFoundation
import Foundation
import Testing
import UIKit
@_spi(Benchmark) @testable import HotMicPlayer

@Suite("Ad break lifecycle") @MainActor
struct AdBreakTests {
    final class Provider: HMAdBreakProvider {
        var calls = 0
        let decide: (HMMediaItem) async throws -> HMAdBreak
        init(_ decide: @escaping (HMMediaItem) async throws -> HMAdBreak) { self.decide = decide }
        func adBreak(for item: HMMediaItem) async throws -> HMAdBreak { calls += 1; return try await decide(item) }
    }
    final class Sink: HMAnalyticsSink {
        let sinkName = "ads-test"
        var outcomes: [String] = []
        var prefetch: [String] = []
        var events: [HMPlaybackEvent] = []
        func handle(_ event: HMPlaybackEvent, item: HMMediaItem) {
            events.append(event)
            if event.kind == .adBreakEnded { outcomes.append(event.properties["outcome"] ?? "") }
            if event.kind == .adPrefetchChanged { prefetch.append(event.properties["paused"] ?? "") }
        }
    }
    private func wait(receipt: (() -> String)? = nil, _ predicate: () -> Bool) async throws {
        let began = ProcessInfo.processInfo.systemUptime, deadline = began + 3
        var last = began, maxGap = 0.0, previous = "", receipts = 0
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
            if let receipt {
                let state = receipt()
                if state != previous && receipts < 8 {
                    nativeTestPhase("host wait state \(state)"); previous = state; receipts += 1
                }
            }
            try await Task.sleep(for: .milliseconds(10))
            let now = ProcessInfo.processInfo.systemUptime
            maxGap = max(maxGap, now - last); last = now
        }
        if let receipt { nativeTestPhase("host wait end elapsed=\(ProcessInfo.processInfo.systemUptime - began) maxResumeGap=\(maxGap) \(receipt())") }
        try #require(predicate())
    }
    @Test("Host completion is one-shot; edits and visibility preserve visits; swipe cancellation invalidates callbacks and protects content heads")
    func hostLifecycle() async throws {
        func phase(_ value: String) { nativeTestPhase("hostLifecycle \(value)") }
        phase("fixture before")
        let url = try await PlayerNativeReviewTests().videoFixture(rotated: false)
        phase("fixture after")
        defer { try? FileManager.default.removeItem(at: url) }
        try await PlayerNativeReviewTests().prepareNativePlayback(url: url)
        phase("native prerequisite complete; host behavior begin")
        let sink = Sink()
        var contexts: [HMHostAdContext] = [], stops: [HMAdOutcome] = []
        let provider = Provider { _ in
            phase("provider decision")
            return .hostPlayed(HMHostAdBreak(start: { contexts.append($0); phase("host start contexts=\(contexts.count)") }, stop: { stops.append($0) }))
        }
        var configuration = HMPlayerConfiguration(managesAudioSession: false); configuration.restoresPlaybackPosition = true
        phase("setup before")
        let player = HMPlayer(configuration: configuration, analytics: HMAnalyticsHub(sinks: [sink]))
        phase("setup after")
        defer { phase("deferred teardown before"); player.teardown(); phase("deferred teardown after") }
        player.adBreakProvider = provider
        let items = ["one", "two", "three"].map { HMMediaItem(id: $0, url: url) }
        phase("replaceAll before"); player.replaceAll(items); phase("replaceAll after")
        phase("context one before")
        try await wait(receipt: {
            let current = player.currentNode, next = player.node(for: items[1])
            return "contexts=\(contexts.count) provider=\(provider.calls) ad=\(player.adState) current=\(current?.item?.id ?? "nil") currentGeneration=\(current?.assignmentGeneration ?? -1) currentStatus=\(String(describing: current?.player.currentItem?.status.rawValue)) next=\(next?.item?.id ?? "nil") nextGeneration=\(next?.assignmentGeneration ?? -1) nextStatus=\(String(describing: next?.player.currentItem?.status.rawValue)) nextFrame=\(next?.snapshot.isFrameReady == true)"
        }) { contexts.count == 1 && player.node(for: items[1]) != nil }
        phase("context one after")
        let content = try #require(player.currentNode)
        let assignment = content.assignmentGeneration
        #expect(!content.isActive && content.snapshot.currentTime == 0)
        #expect(player.preparedItemCount == 2)
        phase("seek before"); player.seek(to: 0.5); phase("seek after"); #expect(content.snapshot.currentTime == 0)
        var permissions: [Bool] = []
        contexts[0].onPlaybackAllowedChange = { permissions.append($0) }
        #expect(contexts[0].isPlaybackAllowed)
        // The SDK's own surface mounts the visit container; edits must not replace it.
        let container = contexts[0].container, surface = HMAdSurfaceView()
        #expect(player.hostAdContext === contexts[0] && container.superview == nil)
        surface.setHostContainer(player.hostAdContext?.container)
        #expect(container.superview === surface)
        phase("permissions and visibility before")
        player.pause(); #expect(!contexts[0].isPlaybackAllowed)
        player.play(); player.isFeedVisible = false; player.isFeedVisible = true
        phase("permissions and visibility after")
        #expect(permissions == [false, true, false, true])
        var metadata = items; metadata[0] = HMMediaItem(id: "one", url: url, title: "new title")
        phase("metadata replaceAll before"); player.replaceAll(metadata); phase("metadata replaceAll after")
        phase("reconcile before"); player.reconcile(metadata); phase("reconcile after")
        #expect(provider.calls == 1 && content.assignmentGeneration == assignment)
        #expect(player.hostAdContext?.container === container && container.superview === surface)
        phase("progress callbacks before")
        contexts[0].updateProgress(HMAdProgress(elapsed: 1, duration: 6))
        #expect(player.adState == .playing(kind: .host) && player.adProgress == HMAdProgress(elapsed: 1, duration: 6))
        for tick in 2...30 { contexts[0].updateProgress(HMAdProgress(elapsed: Double(tick), duration: 60)) }
        phase("progress callbacks after")
        #expect(sink.events.filter { $0.kind == .adStateChanged }.map { $0.properties["state"] } == ["loading", "playing"])
        #expect(sink.events.allSatisfy { ![.seeking, .seeked, .pause].contains($0.kind) })
        phase("skip and stale completion before"); player.skipAd(); contexts[0].complete(); contexts[0].fail(); phase("skip and stale completion after")
        #expect(stops == [.skipped] && sink.outcomes == ["skipped"])
        #expect(player.hostAdContext == nil && container.superview == nil && !contexts[0].isPlaybackAllowed)
        #expect(!player.adState.isActive && content.isActive && content.assignmentGeneration == assignment)
        let start = try #require(sink.events.last { $0.kind == .viewStart })
        #expect(start.properties["after_ad"] == "true" && start.properties["ad_outcome"] == "skipped")
        phase("next before"); player.next(); phase("next after")
        phase("context two before")
        try await wait { contexts.count == 2 }
        phase("context two after")
        phase("swipe before")
        player.configuration.allowsSwipeDuringAds = false
        player.requestPage(at: 2); #expect(player.requestedPageID == nil)
        player.commitPage(toID: "three", requestedAt: 0); #expect(player.currentItem?.id == "two")
        player.configuration.allowsSwipeDuringAds = true
        player.commitPage(toID: "three", requestedAt: ProcessInfo.processInfo.systemUptime)
        phase("swipe after")
        phase("context three before")
        try await wait { contexts.count == 3 }
        phase("context three after")
        #expect(stops == [.skipped, .cancelled])
        contexts[1].complete(); contexts[1].updateProgress(HMAdProgress(elapsed: 100))
        #expect(player.adState.isActive && player.currentItem?.id == "three")
        surface.setHostContainer(player.hostAdContext?.container)
        #expect(contexts[2].container !== container && contexts[2].container.superview === surface && container.superview == nil)
        phase("teardown and stale completion before"); player.teardown(); contexts[2].complete(); phase("teardown and stale completion after")
        #expect(stops == [.skipped, .cancelled, .cancelled])
        #expect(contexts[2].container.superview == nil && surface.subviews == [surface.video])
        #expect(sink.prefetch == ["true", "false", "true", "false", "true", "false"])
    }
    @Test("Decision deadline fails open even when cancellation is ignored; a late host result cannot start")
    func decisionDeadline() async throws {
        let url = try await PlayerNativeReviewTests().videoFixture(rotated: false)
        defer { try? FileManager.default.removeItem(at: url) }
        var continuation: CheckedContinuation<HMAdBreak, Never>?
        var starts = 0, stops: [HMAdOutcome] = []
        let provider = Provider { _ in await withCheckedContinuation { continuation = $0 } }
        var c = HMPlayerConfiguration(managesAudioSession: false); c.adDecisionTimeout = 0.05
        let sink = Sink(), player = HMPlayer(configuration: c, analytics: HMAnalyticsHub(sinks: [sink]))
        defer { player.teardown() }
        player.adBreakProvider = provider; player.replaceAll([HMMediaItem(id: "slow", url: url)])
        try await wait { player.adState == .finished }
        try await wait { player.currentNode?.isActive == true }
        continuation?.resume(returning: .hostPlayed(HMHostAdBreak(start: { _ in starts += 1 }, stop: { stops.append($0) })))
        continuation = nil
        try await Task.sleep(for: .milliseconds(30))
        #expect(starts == 0 && provider.calls == 1 && sink.outcomes == ["timedOut"])
        #expect(stops == [.cancelled])
        player.play(); #expect(provider.calls == 1)
    }
    @Test("URL startup timeout and decision failures release ad work and resume content", arguments: ["startup", "invalid", "throw"])
    func failOpen(mode: String) async throws {
        let url = try await PlayerNativeReviewTests().videoFixture(rotated: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = Provider { _ in
            if mode == "throw" { throw HMPlayerError.playback("fake SDK") }
            return .preRoll(HMMediaItem(id: "ad", url: mode == "invalid" ? URL(string: "ftp://invalid/ad.mp4")! : url))
        }
        var c = HMPlayerConfiguration(managesAudioSession: false); c.adLoadTimeout = 0.1
        let sink = Sink(), player = HMPlayer(configuration: c, analytics: HMAnalyticsHub(sinks: [sink]))
        defer { player.teardown() }
        player.adBreakProvider = provider; player.replaceAll([HMMediaItem(id: "content", url: url)])
        try await wait { player.adState == .finished && player.currentNode?.isActive == true }
        #expect(player.adNode == nil && player.hostAdContext == nil)
        #expect(sink.outcomes == [mode == "startup" ? "timedOut" : "failed"])
        #expect(sink.prefetch == ["true", "false"])
        let start = try #require(sink.events.last { $0.kind == .viewStart })
        #expect(start.properties["after_ad"] == (mode == "startup" || mode == "invalid" ? "true" : "false"))
        if mode == "startup" {
            #expect(start.monotonicTime - (start.metrics["request_monotonic_s"] ?? start.monotonicTime) >= 0.1)
            #expect(start.properties["ad_outcome"] == "timedOut")
        }
    }

    @Test("Accepted breaks escape hung renderers even with paging blocked", arguments: ["host-idle", "host-cap", "url-idle", "url-cap"])
    func watchdog(mode: String) async throws {
        let url = try await PlayerNativeReviewTests().videoFixture(rotated: false)
        defer { try? FileManager.default.removeItem(at: url) }
        var context: HMHostAdContext?, stops: [HMAdOutcome] = []
        let ad = HMMediaItem(id: "ad", url: url)
        let provider = Provider { _ in
            mode.hasPrefix("url") ? .preRoll(ad) : .hostPlayed(HMHostAdBreak(start: { context = $0 }, stop: { stops.append($0) }))
        }
        var c = HMPlayerConfiguration(managesAudioSession: false)
        c.allowsSwipeDuringAds = false
        c.adNoProgressTimeout = mode.hasSuffix("idle") ? 0.15 : 10
        c.adBreakMaxDuration = mode.hasSuffix("cap") ? 0.25 : 10
        let sink = Sink(), player = HMPlayer(configuration: c, analytics: HMAnalyticsHub(sinks: [sink]))
        defer { player.teardown() }
        player.pause() // Prior content pause must not freeze the new break.
        player.adBreakProvider = provider; player.replaceAll([HMMediaItem(id: "content", url: url)])
        if mode.hasPrefix("url") {
            try await wait { player.adNode != nil }
            let node = try #require(player.adNode)
            // Model a decoder that displayed its first frame, then stalled permanently.
            node.onEvent?(HMPlaybackEvent(kind: .firstFrame, itemID: ad.id), ad)
            node.player.pause()
        } else {
            try await wait { context != nil }
            #expect(context?.isPlaybackAllowed == true)
        }
        #expect(player.isAdSwipeBlocked)
        try await wait { player.adState == .finished && player.currentNode?.isActive == true }
        #expect(sink.outcomes == ["timedOut"] && !player.isAdSwipeBlocked)
        #expect(player.adNode == nil && player.hostAdContext == nil)
        if mode.hasPrefix("host") { #expect(stops == [.timedOut]) }
    }

    @Test("Decision and accepted breaks preserve back-swipe assignments; removing current cancels finish-once", arguments: [false, true])
    func retainedNeighbours(host: Bool) async throws {
        let url = try await PlayerNativeReviewTests().videoFixture(rotated: false)
        defer { try? FileManager.default.removeItem(at: url) }
        var c = HMPlayerConfiguration(poolSize: 3, managesAudioSession: false)
        c.removedCurrentPolicy = .finishThenAdvance
        let sink = Sink(), player = HMPlayer(configuration: c, analytics: HMAnalyticsHub(sinks: [sink]))
        defer { player.teardown() }
        let items = ["one", "two", "three"].map { HMMediaItem(id: $0, url: url) }
        player.replaceAll(items)
        try await wait { player.currentNode?.isActive == true }
        let previous = try #require(player.currentNode)
        let generation = previous.assignmentGeneration
        var continuation: CheckedContinuation<HMAdBreak, Never>?, stops: [HMAdOutcome] = []
        let provider = Provider { _ in await withCheckedContinuation { continuation = $0 } }
        player.adBreakProvider = provider; player.next()
        try await wait { continuation != nil }
        #expect(player.node(for: items[0]) === previous && previous.assignmentGeneration == generation)
        continuation?.resume(returning: host ? .hostPlayed(HMHostAdBreak(start: { _ in }, stop: { stops.append($0) })) : .none)
        continuation = nil
        try await wait { host ? player.adState == .playing(kind: .host) : player.adState == .finished }
        #expect(player.node(for: items[0]) === previous && previous.assignmentGeneration == generation)
        if host {
            player.remove(ids: ["two"])
            #expect(player.currentItem?.id == "three" && !player.items.contains { $0.id == "two" })
            #expect(stops == [.cancelled])
            // Resolve the new visit before teardown, avoiding a dangling test continuation.
            try await wait { continuation != nil }
            continuation?.resume(returning: .none); continuation = nil
            try await wait { player.adState == .finished }
        } else {
            #expect(sink.outcomes == ["noFill"] && sink.prefetch == ["true", "false"])
            player.previous()
            try await wait { continuation != nil }
            continuation?.resume(returning: .none); continuation = nil
            try await wait { player.adState == .finished && previous.isActive }
            #expect(previous.assignmentGeneration == generation)
        }
    }
}
#endif
