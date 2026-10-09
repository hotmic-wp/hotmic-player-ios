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
        for mode in ["selection", "swipe", "programmatic"] {
            let resolver = GatedResolver(), sink = Sink(), hub = HMAnalyticsHub(); hub.add(sink)
            var c = HMPlayerConfiguration(poolSize: 1, prefetch: .off, managesAudioSession: false, failedItemPolicy: .stay)
            c.resolveAhead = 0
            let player = HMPlayer(configuration: c, resolver: resolver, analytics: hub)
            defer { player.teardown() }
            let entry = HMMediaItem.reference("hotmic", id: "delayed")
            var clock = ProcessInfo.processInfo.systemUptime
            if mode == "selection" {
                player.replaceAll([entry])
            } else {
                player.isFeedVisible = false
                player.replaceAll([HMMediaItem(id: "seed", url: URL(fileURLWithPath: "/tmp/hotmic-031-seed.mp4")), entry])
                if mode == "programmatic" { player.requestPage(at: 1) }
                try await Task.sleep(for: .milliseconds(150))
                clock = ProcessInfo.processInfo.systemUptime
                player.commitPage(toID: entry.id, requestedAt: clock)
                player.isFeedVisible = true
            }
            try await wait { await resolver.calls == 1 }
            #expect(player.snapshot.state == .loading); #expect(player.snapshot.readinessTier == .resolving)
            #expect(player.node(for: entry) == nil)
            let flag = ChangeFlag()
            withObservationTracking { _ = player.node(for: entry) } onChange: { flag.mark() }
            player.commitPage(toID: entry.id, requestedAt: clock + 50)
            await resolver.complete(format: format)
            try await wait { player.node(for: entry)?.isActive == true }
            #expect(flag.changed); #expect(player.currentItem == entry)
            #expect(player.node(for: entry)?.item?.format == format); #expect(sink.starts.count == 1)
            let request = try #require(sink.starts.first?.metrics["request_monotonic_s"])
            #expect(abs(request - clock) < 0.1)
            #expect(player.snapshot.readinessTier == .resolved); #expect(await resolver.calls == 1)
        }
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
        player.attachFeed(); player.beginInteraction(); player.setPageMoving(true)
        player.replaceAll([a, bad, b], startAt: 1)
        try await wait(until: { await resolver.calls == 3 && player.snapshot.state == .failed && errors == 3 }, seconds: 5)
        #expect(errors == 3); #expect(player.currentItem == bad); #expect(player.requestedPageID == nil)
        player.isFeedVisible = false // No real media IO is needed for the page-commit assertions.
        player.endInteraction()
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
        #expect(player.currentIndex == nil); #expect(player.activeIndex == 0)
        #expect(await resolver.calls == 3)
        // Headless traversal also terminates, with no failed entry retried by an automatic skip.
        player.detachFeed(); player.replaceAll([a, b])
        player.pool.onEvent?(HMPlaybackEvent(kind: .error, itemID: a.id), a)
        try await wait { player.currentItem == b }
        player.pool.onEvent?(HMPlaybackEvent(kind: .error, itemID: b.id), b)
        try await wait { player.currentItem == nil }
        // A restored NWPath clears remembered terminal entries, including idle traversal.
        player.connectivityChanged(satisfied: false); player.connectivityChanged(satisfied: true)
        #expect(player.currentItem == b); #expect(player.currentIndex == 1)
        player.pool.onEvent?(HMPlaybackEvent(kind: .error, itemID: b.id), b)
        try await wait { player.currentItem == a }
        player.configuration.failedItemPolicy = .stay
        player.replaceAll([a, b])
        let priorErrors = errors
        player.pool.onEvent?(HMPlaybackEvent(kind: .error, itemID: a.id), a)
        try await wait { errors > priorErrors }
        #expect(player.currentItem == a); #expect(player.requestedPageID == nil)
        player.configuration.failedItemPolicy = .skip
        try await wait { player.currentItem == b }

        // Every requested connectivity code, including nested AV errors, stays current.
        let codes: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .timedOut,
            .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed]
        player.replaceAll([a, b])
        for code in codes {
            let error = URLError(code) as NSError
            #expect(HMNetworkFailure.isTransient(error))
            #expect(HMNetworkFailure.isTransient(NSError(domain: "AVFoundationErrorDomain", code: -11800,
                userInfo: [NSUnderlyingErrorKey: error])))
            player.pool.onEvent?(HMPlaybackEvent(kind: .error, itemID: a.id,
                properties: ["error_domain": NSURLErrorDomain, "error_code": String(code.rawValue)]), a)
            try await Task.sleep(for: .milliseconds(10))
            #expect(player.currentItem == a); #expect(player.requestedPageID == nil)
        }
        #expect(!HMNetworkFailure.isTransient(URLError(.badServerResponse)))
        var backoff = HMNetworkRetry()
        for delay in [1.0, 2, 4, 8, 16, 30, 30] {
            backoff.failed(at: 100)
            #expect(backoff.nextAttempt == 100 + delay)
        }

        // Repeated resolver connectivity failures do not consume the terminal budget.
        let net = NetworkResolver()
        let recovering = HMPlayer(configuration: c, resolver: net)
        defer { recovering.teardown() }
        let offline = HMMediaItem.reference("hotmic", id: "offline")
        recovering.replaceAll([offline, bad])
        try await wait(until: { await net.calls >= 4 }, seconds: 9)
        #expect(recovering.currentItem == offline); #expect(recovering.snapshot.state == .loading)
        recovering.configuration.failedItemPolicy = .stay
        await net.goOnline()
        recovering.connectivityChanged(satisfied: false); recovering.connectivityChanged(satisfied: true)
        try await wait { recovering.node(for: offline)?.isActive == true }
        #expect(recovering.currentItem == offline)

        // A pending final page must win over a previous-item fallback (including an empty page).
        for empty in [false, true] {
            player.playlistSource = nil
            player.replaceAll([a, b], startAt: 1)
            let appended = HMMediaItem(id: "page", url: a.url!)
            let source = GatedPage(items: empty ? [] : [appended])
            player.playlistSource = source
            let loading = Task { await player.loadNextPage() }
            try await wait { await source.started }
            player.pool.onEvent?(HMPlaybackEvent(kind: .error, itemID: b.id), b)
            try await Task.sleep(for: .milliseconds(30))
            #expect(player.currentItem == b); #expect(player.isLoadingPage); #expect(player.hasMoreContent)
            await source.complete(); await loading.value
            try await wait { player.currentItem == (empty ? a : appended) }
        }
        player.playlistSource = nil
        player.attachFeed(); player.replaceAll([a, b])
        player.pool.onEvent?(HMPlaybackEvent(kind: .error, itemID: a.id), a)
        try await wait { player.requestedPageID == b.id }
        let oldRequest = player.pageRequestID
        player.append([HMMediaItem(id: "tail", url: a.url!)])
        try await wait { player.requestedPageID == b.id && player.pageRequestID != oldRequest }
        // A partner interaction beginning after a request defers commit and expires by itself.
        player.beginInteraction(timeout: .milliseconds(100))
        #expect(player.isInteracting); #expect(player.requestedPageIndex == nil)
        player.commitPage(toID: b.id, requestedAt: ProcessInfo.processInfo.systemUptime)
        #expect(player.currentItem == a)
        try await wait { !player.isInteracting && player.currentItem == b }
        player.detachFeed()
    }

    actor NetworkResolver: HMItemResolver {
        var calls = 0
        var offline = true
        func goOnline() { offline = false }
        func resolve(_ ref: HMMediaItem.Reference) async throws -> HMResolvedItem {
            calls += 1
            if offline { throw URLError(.notConnectedToInternet) }
            return HMResolvedItem(url: URL(fileURLWithPath: "/tmp/hotmic-031-recovered.mp4"))
        }
    }
    actor GatedPage: HMPlaylistSource {
        let items: [HMMediaItem]
        var started = false
        var gate: CheckedContinuation<Void, Never>?
        init(items: [HMMediaItem]) { self.items = items }
        func loadPage(cursor: String?) async throws -> HMPlaylistPage {
            started = true
            await withCheckedContinuation { gate = $0 }
            return HMPlaylistPage(items: items, nextCursor: nil)
        }
        func complete() { gate?.resume(); gate = nil }
    }
}
#endif
