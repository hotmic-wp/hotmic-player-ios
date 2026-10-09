#if canImport(AVFoundation) && !os(macOS)
import Foundation
import Observation
import Testing
@_spi(Benchmark) @testable import HotMicPlayer

@Suite("0.3.1 playlist/resolution regressions") @MainActor
struct Player031Tests {
    actor GatedResolver: HMItemResolver {
        var calls = 0
        var gate: CheckedContinuation<HMResolvedItem, Error>?
        func resolve(_ ref: HMMediaItem.Reference) async throws -> HMResolvedItem {
            calls += 1
            return try await withCheckedThrowingContinuation { gate = $0 }
        }
        func complete(format: HMMediaItem.Format) {
            gate?.resume(returning: HMResolvedItem(url: URL(fileURLWithPath: "/tmp/hotmic-031-fixture.\(format == .hls ? "m3u8" : "mp4")"), format: format))
            gate = nil
        }
    }
    final class ChangeFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func mark() { lock.lock(); defer { lock.unlock() }; value = true }
        var changed: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    final class Sink: HMAnalyticsSink {
        let sinkName = "031-test"
        var starts: [HMPlaybackEvent] = []
        func handle(_ event: HMPlaybackEvent, item: HMMediaItem) { if event.kind == .viewStart { starts.append(event) } }
    }
    private func wait(until predicate: () async -> Bool, seconds: Double = 2) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !(await predicate()), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await predicate())
    }
    @Test("Resolution invalidates the initially node-less cell and activates once with the action clock", arguments: [HMMediaItem.Format.hls, .mp4])
    func activationAfterResolution(format: HMMediaItem.Format) async throws {
        let resolver = GatedResolver(), sink = Sink(), hub = HMAnalyticsHub(); hub.add(sink)
        var c = HMPlayerConfiguration(poolSize: 1, prefetch: .off, managesAudioSession: false, failedItemPolicy: .stay)
        c.resolveAhead = 0
        let player = HMPlayer(configuration: c, resolver: resolver, analytics: hub)
        defer { player.teardown() }
        let entry = HMMediaItem.reference("hotmic", id: "delayed")
        let actionAt = ProcessInfo.processInfo.systemUptime
        player.replaceAll([entry])
        try await wait { await resolver.calls == 1 }
        #expect(player.snapshot.state == .loading); #expect(player.snapshot.readinessTier == .resolving)
        #expect(player.node(for: entry) == nil)
        let flag = ChangeFlag()
        withObservationTracking { _ = player.node(for: entry) } onChange: { flag.mark() }
        // A duplicate settle while resolving must not restart TTFF or the retry budget.
        player.commitPage(toID: entry.id, requestedAt: actionAt + 50)
        await resolver.complete(format: format)
        try await wait { player.node(for: entry)?.isActive == true }
        #expect(flag.changed)
        #expect(player.currentItem == entry)
        #expect(player.node(for: entry)?.item?.format == format)
        #expect(sink.starts.count == 1)
        let request = try #require(sink.starts.first?.metrics["request_monotonic_s"])
        #expect(abs(request - actionAt) < 0.1)
        #expect(player.snapshot.readinessTier == .resolved)
        #expect(await resolver.calls == 1)
    }

    actor FailingResolver: HMItemResolver {
        var calls = 0
        func resolve(_ ref: HMMediaItem.Reference) async throws -> HMResolvedItem {
            calls += 1
            throw HMPlayerError.resolution("Terminal fixture")
        }
    }
    @Test("Terminal resolution/media errors obey skip/stay, defer interaction, commit pages and bound all-failing traversal")
    func failedItemPolicy() async throws {
        #expect(HMPlayerConfiguration.default.failedItemPolicy == .skip)
        let resolver = FailingResolver()
        var c = HMPlayerConfiguration(poolSize: 1, prefetch: .off, managesAudioSession: false)
        c.resolveAhead = 0
        let player = HMPlayer(configuration: c, resolver: resolver)
        let bad = HMMediaItem.reference("hotmic", id: "bad")
        let a = HMMediaItem(id: "a", url: URL(fileURLWithPath: "/tmp/hotmic-031-a.mp4"))
        let b = HMMediaItem(id: "b", url: URL(fileURLWithPath: "/tmp/hotmic-031-b.mp4"))
        var errors = 0
        let events = player.events
        let consumer = Task { for await event in events { if case .error = event { errors += 1 } } }
        defer { player.teardown(); consumer.cancel() }
        player.attachFeed(); player.isInteracting = true; player.setPageMoving(true)
        player.replaceAll([a, bad, b], startAt: 1)
        try await wait(until: { await resolver.calls == 3 && player.snapshot.state == .failed && errors == 3 }, seconds: 5)
        #expect(errors == 3); #expect(player.currentItem == bad); #expect(player.requestedPageID == nil)
        player.isFeedVisible = false // No real media IO is needed for the page-commit assertions.
        player.isInteracting = false
        try await Task.sleep(for: .milliseconds(30))
        #expect(player.currentItem == bad); #expect(player.requestedPageID == nil)
        player.setPageMoving(false)
        try await wait { player.requestedPageID == b.id }
        #expect(player.currentItem == bad) // Scroll first, commit second.
        player.commitPage(toID: b.id, requestedAt: ProcessInfo.processInfo.systemUptime)
        #expect(player.currentItem == b)
        #expect(await resolver.calls == 3)
        // Native terminal failure at the end searches backwards, bypassing known failures.
        player.pool.onEvent?(HMPlaybackEvent(kind: .error, itemID: b.id), b)
        try await wait { player.requestedPageID == a.id }
        player.commitPage(toID: a.id, requestedAt: ProcessInfo.processInfo.systemUptime)
        #expect(player.currentItem == a)
        player.pool.onEvent?(HMPlaybackEvent(kind: .error, itemID: a.id), a)
        try await wait { player.currentItem == nil }
        #expect(player.snapshot.state == .idle); #expect(player.items == [a, bad, b])
        #expect(await resolver.calls == 3)
        // Headless traversal also terminates, with no failed entry retried by an automatic skip.
        player.detachFeed(); player.replaceAll([a, b])
        player.pool.onEvent?(HMPlaybackEvent(kind: .error, itemID: a.id), a)
        try await wait { player.currentItem == b }
        player.pool.onEvent?(HMPlaybackEvent(kind: .error, itemID: b.id), b)
        try await wait { player.currentItem == nil }
        player.configuration.failedItemPolicy = .stay
        player.replaceAll([a, b])
        let priorErrors = errors
        player.pool.onEvent?(HMPlaybackEvent(kind: .error, itemID: a.id), a)
        try await wait { errors > priorErrors }
        #expect(player.currentItem == a); #expect(player.requestedPageID == nil)
        player.configuration.failedItemPolicy = .skip
        try await wait { player.currentItem == b }
    }
}
#endif
