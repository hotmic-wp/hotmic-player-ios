#if canImport(UIKit) && !os(watchOS)
import AVFoundation
import Foundation
import Testing
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
        func handle(_ event: HMPlaybackEvent, item: HMMediaItem) {
            if event.kind == .adBreakEnded { outcomes.append(event.properties["outcome"] ?? "") }
            if event.kind == .adPrefetchChanged { prefetch.append(event.properties["paused"] ?? "") }
        }
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(predicate())
    }
    @Test("Host completion is one-shot; edits and visibility preserve visits; swipe cancellation invalidates callbacks and protects content heads")
    func hostLifecycle() async throws {
        let url = try await PlayerNativeReviewTests().videoFixture(rotated: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = Sink()
        var contexts: [HMHostAdContext] = [], stops: [HMAdOutcome] = []
        let provider = Provider { _ in .hostPlayed(HMHostAdBreak(start: { contexts.append($0) }, stop: { stops.append($0) })) }
        var configuration = HMPlayerConfiguration(managesAudioSession: false); configuration.restoresPlaybackPosition = true
        let player = HMPlayer(configuration: configuration, analytics: HMAnalyticsHub(sinks: [sink]))
        defer { player.teardown() }
        player.adBreakProvider = provider
        let items = ["one", "two", "three"].map { HMMediaItem(id: $0, url: url) }
        player.replaceAll(items)
        try await wait { contexts.count == 1 && player.node(for: items[1]) != nil }
        let content = try #require(player.currentNode)
        let assignment = content.assignmentGeneration
        #expect(!content.isActive && content.snapshot.currentTime == 0)
        #expect(player.preparedItemCount == 2)
        player.seek(to: 0.5); #expect(content.snapshot.currentTime == 0)
        player.pause(); player.play(); player.isFeedVisible = false; player.isFeedVisible = true
        var metadata = items; metadata[0] = HMMediaItem(id: "one", url: url, title: "new title")
        player.replaceAll(metadata)
        #expect(provider.calls == 1 && content.assignmentGeneration == assignment)
        contexts[0].updateProgress(HMAdProgress(elapsed: 1, duration: 6))
        #expect(player.adState == .playing(kind: .host, progress: HMAdProgress(elapsed: 1, duration: 6)))
        player.skipAd(); contexts[0].complete(); contexts[0].fail()
        #expect(stops == [.skipped] && sink.outcomes == ["skipped"])
        #expect(!player.adState.isActive && content.isActive && content.assignmentGeneration == assignment)
        player.next()
        try await wait { contexts.count == 2 }
        player.configuration.allowsSwipeDuringAds = false
        player.requestPage(at: 2); #expect(player.requestedPageID == nil)
        player.commitPage(toID: "three", requestedAt: 0); #expect(player.currentItem?.id == "two")
        player.configuration.allowsSwipeDuringAds = true
        player.commitPage(toID: "three", requestedAt: ProcessInfo.processInfo.systemUptime)
        try await wait { contexts.count == 3 }
        #expect(stops == [.skipped, .cancelled])
        contexts[1].complete(); contexts[1].updateProgress(HMAdProgress(elapsed: 100))
        #expect(player.adState.isActive && player.currentItem?.id == "three")
        player.teardown(); contexts[2].complete()
        #expect(stops == [.skipped, .cancelled, .cancelled])
        #expect(sink.prefetch == ["true", "false", "true", "false", "true", "false"])
    }
    @Test("Decision deadline fails open even when cancellation is ignored; a late host result cannot start")
    func decisionDeadline() async throws {
        let url = try await PlayerNativeReviewTests().videoFixture(rotated: false)
        defer { try? FileManager.default.removeItem(at: url) }
        var continuation: CheckedContinuation<HMAdBreak, Never>?
        var starts = 0
        let provider = Provider { _ in await withCheckedContinuation { continuation = $0 } }
        var c = HMPlayerConfiguration(managesAudioSession: false); c.adDecisionTimeout = 0.05
        let sink = Sink(), player = HMPlayer(configuration: c, analytics: HMAnalyticsHub(sinks: [sink]))
        defer { player.teardown() }
        player.adBreakProvider = provider; player.replaceAll([HMMediaItem(id: "slow", url: url)])
        try await wait { player.adState == .finished }
        try await wait { player.currentNode?.isActive == true }
        continuation?.resume(returning: .hostPlayed(HMHostAdBreak(start: { _ in starts += 1 })))
        continuation = nil
        try await Task.sleep(for: .milliseconds(30))
        #expect(starts == 0 && provider.calls == 1 && sink.outcomes == ["timedOut"])
        player.play(); #expect(provider.calls == 1)
    }
    @Test("URL startup timeout and decision failures release ad work and resume content", arguments: ["startup", "invalid", "throw", "none"])
    func failOpen(mode: String) async throws {
        let url = try await PlayerNativeReviewTests().videoFixture(rotated: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let provider = Provider { _ in
            if mode == "throw" { throw HMPlayerError.playback("fake SDK") }
            if mode == "none" { return .none }
            return .preRoll(HMMediaItem(id: "ad", url: mode == "invalid" ? URL(string: "ftp://invalid/ad.mp4")! : url))
        }
        var c = HMPlayerConfiguration(managesAudioSession: false); c.adLoadTimeout = 0.1
        let sink = Sink(), player = HMPlayer(configuration: c, analytics: HMAnalyticsHub(sinks: [sink]))
        defer { player.teardown() }
        player.adBreakProvider = provider; player.replaceAll([HMMediaItem(id: "content", url: url)])
        try await wait { player.adState == .finished && player.currentNode?.isActive == true }
        #expect(player.adNode == nil && player.hostAdContext == nil)
        #expect(sink.outcomes == [mode == "startup" ? "timedOut" : mode == "none" ? "noFill" : "failed"])
        #expect(sink.prefetch == ["true", "false"])
    }
}
#endif
