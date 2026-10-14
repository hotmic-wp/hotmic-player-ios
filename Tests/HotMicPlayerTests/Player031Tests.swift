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
            gate?.resume(returning: HMResolvedItem(url: FileManager.default.temporaryDirectory.appendingPathComponent("hotmic-031-fixture.\(format == .hls ? "m3u8" : "mp4")"), format: format))
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
    private func wait(until predicate: () async -> Bool, seconds: Double = 2, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !(await predicate()), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await predicate(), sourceLocation: sourceLocation)
    }
    @Test("Resolution invalidates the initially node-less cell and activates once with the action clock", arguments: [HMMediaItem.Format.hls, .mp4])
    func activationAfterResolution(format: HMMediaItem.Format) async throws {
        #expect(HMPlayerNode.grantsSeekCatchupGrace(hasPlayableBuffer: true, elapsed: 0.0068))
        #expect(!HMPlayerNode.grantsSeekCatchupGrace(hasPlayableBuffer: true, elapsed: 0.151))
        #expect(!HMPlayerNode.grantsSeekCatchupGrace(hasPlayableBuffer: false, elapsed: 0))
        let defaults = HMPlayer()
        #expect(defaults.configuration.prefetch == HMPlayerConfiguration.default.prefetch && !defaults.configuration.adaptive)
        #expect(defaults.pool.nodes.count == 2)
        defaults.teardown()
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
                player.replaceAll([HMMediaItem(id: "seed", url: FileManager.default.temporaryDirectory.appendingPathComponent("hotmic-031-seed.mp4")), entry])
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
        // Success branches own playable media; native missing-file errors must not race policy assertions.
        let media = try await PlayerNativeReviewTests().videoFixture(rotated: false, duration: 20)
        defer { try? FileManager.default.removeItem(at: media) }
        let a = HMMediaItem(id: "a", url: media)
        let b = HMMediaItem(id: "b", url: media)
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
        player.detachFeed(); player.replaceAll([a, b]); player.jump(toID: b.id); player.jump(toID: a.id)
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
        // An identical replaceAll is now a no-op, including remembered failures.
        // Explicitly retry each ID to start a fresh failure scenario.
        player.replaceAll([a, b], startAt: 1); player.jump(toID: b.id); player.jump(toID: a.id)
        let priorErrors = errors
        player.pool.onEvent?(HMPlaybackEvent(kind: .error, itemID: a.id), a)
        try await wait { errors > priorErrors }
        #expect(player.currentItem == a); #expect(player.requestedPageID == nil)
        player.configuration.failedItemPolicy = .skip
        try await wait { player.currentItem == b }

        // Every requested connectivity code, including nested AV errors, stays current.
        let codes: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .timedOut,
            .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed]
        player.replaceAll([a, b]); player.jump(toID: a.id)
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
        // Bounded exponential backoff with ±25% jitter, so recovering clients don't retry in lockstep.
        var backoff = HMNetworkRetry(), low = HMNetworkRetry(), high = HMNetworkRetry(), random = HMNetworkRetry()
        var samples: Set<Double> = []
        for delay in [1.0, 2, 4, 8, 16, 30, 30] {
            backoff.failed(at: 100, jitter: 1); low.failed(at: 100, jitter: 0.1); high.failed(at: 100, jitter: 9)
            random.failed(at: 100)
            #expect(backoff.nextAttempt == 100 + delay)
            #expect(low.nextAttempt == 100 + delay * 0.75); #expect(high.nextAttempt == 100 + delay * 1.25)
            #expect((100 + delay * 0.75)...(100 + delay * 1.25) ~= random.nextAttempt)
            samples.insert(random.nextAttempt - 100 - delay)
        }
        #expect(samples.count > 1)

        // Repeated resolver connectivity failures do not consume the terminal budget.
        let net = NetworkResolver(media: media)
        let recovering = HMPlayer(configuration: c, resolver: net)
        var networkErrors = 0
        let networkEvents = recovering.events
        let networkConsumer = Task { for await event in networkEvents { if case .error = event { networkErrors += 1 } } }
        defer { recovering.teardown(); networkConsumer.cancel() }
        let offline = HMMediaItem.reference("hotmic", id: "offline")
        recovering.replaceAll([offline, bad])
        // Three uninterrupted retry delays can total 8.75s at maximum jitter.
        // Keep the helper's normal 2s scheduling allowance beyond that policy maximum.
        let retryDeadline = (1.0 + 2 + 4) * HMNetworkRetry.jitter.upperBound + 2
        try await wait(until: { await net.calls >= 4 && networkErrors >= 4 }, seconds: retryDeadline)
        #expect(recovering.currentItem == offline); #expect(recovering.snapshot.state == .loading)
        recovering.configuration.failedItemPolicy = .stay
        await net.goOnline()
        recovering.connectivityChanged(satisfied: false); recovering.connectivityChanged(satisfied: true)
        // The unhosted runner has no visible layer; require native media readiness.
        try await wait { recovering.node(for: offline)?.isActive == true && recovering.node(for: offline)?.player.currentItem?.status == .readyToPlay }
        recovering.pause()
        #expect(recovering.currentItem == offline)

        // A pending final page must win over a previous-item fallback (including an empty page).
        for empty in [false, true] {
            player.playlistSource = nil
            player.replaceAll([a, b], startAt: 1); player.jump(toID: b.id)
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
        player.attachFeed()
        // Previous scenarios marked b terminal; explicitly retry both fixture IDs.
        player.replaceAll([a, b], startAt: 1); player.jump(toID: b.id); player.jump(toID: a.id)
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

    actor RefreshFailureResolver: HMItemResolver {
        var calls = 0
        let network: Bool
        init(network: Bool) { self.network = network }
        func resolve(_ ref: HMMediaItem.Reference) async throws -> HMResolvedItem {
            calls += 1
            if network { throw URLError(.notConnectedToInternet) }
            throw HMPlayerError.resolution("Refresh failure")
        }
    }
    @Test("Metadata refresh preserves resolution/network backoff and terminal memory; jump retries", arguments: ["resolution", "terminal", "network"])
    func refreshFailureMemory(mode: String) async throws {
        var configuration = HMPlayerConfiguration(poolSize: 1, prefetch: .off, managesAudioSession: false, failedItemPolicy: .stay)
        configuration.resolveAhead = 0
        let resolver = RefreshFailureResolver(network: mode == "network")
        let player = HMPlayer(configuration: configuration, resolver: resolver)
        defer { player.teardown() }
        let item = HMMediaItem.reference("hotmic", id: "refresh-failure")
        player.replaceAll([item])
        let attempts = mode == "terminal" ? 3 : 1
        try await wait(until: { await resolver.calls == attempts && player.loadError != nil && (mode != "terminal" || player.snapshot.state == .failed) }, seconds: 5)
        for title in ["Refresh 1", "Refresh 2", "Refresh 3"] {
            player.replaceAll([HMMediaItem(id: item.id, source: item.source, title: title)])
            try await Task.sleep(for: .milliseconds(60))
            #expect(await resolver.calls == attempts)
        }
        player.replaceAll(player.items)
        #expect(await resolver.calls == attempts)
        player.jump(toID: item.id)
        try await wait { await resolver.calls == attempts + 1 }
    }

    actor FailingPages: HMPlaylistSource {
        var calls = 0
        func loadPage(cursor: String?) async throws -> HMPlaylistPage {
            calls += 1
            throw URLError(.badServerResponse)
        }
    }
    @Test("A failed last item falls back to previous once paging retries are exhausted")
    func exhaustedPagingFallback() async throws {
        var c = HMPlayerConfiguration(poolSize: 1, prefetch: .off, managesAudioSession: false)
        c.resolveAhead = 0
        let player = HMPlayer(configuration: c)
        defer { player.teardown() }
        let a = HMMediaItem(id: "a", url: FileManager.default.temporaryDirectory.appendingPathComponent("hotmic-040-a.mp4"))
        let b = HMMediaItem(id: "b", url: FileManager.default.temporaryDirectory.appendingPathComponent("hotmic-040-b.mp4"))
        let source = FailingPages()
        player.isFeedVisible = false
        player.playlistSource = source
        player.replaceAll([a, b], startAt: 1)
        player.pool.onEvent?(HMPlaybackEvent(kind: .error, itemID: b.id), b)
        // While paging still has retries left, a next page may arrive: stay on the failed item.
        try await Task.sleep(for: .milliseconds(300))
        #expect(player.currentItem == b); #expect(player.hasMoreContent)
        // Four attempts with 1/2/4 s waits, then the previous item takes over.
        try await wait(until: { player.currentItem == a }, seconds: 12)
        #expect(await source.calls >= 4); #expect(player.hasMoreContent)
    }

    actor NetworkResolver: HMItemResolver {
        var calls = 0
        var offline = true
        let media: URL
        init(media: URL) { self.media = media }
        func goOnline() { offline = false }
        func resolve(_ ref: HMMediaItem.Reference) async throws -> HMResolvedItem {
            calls += 1
            if offline { throw URLError(.notConnectedToInternet) }
            return HMResolvedItem(url: media)
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
