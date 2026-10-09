import Foundation
import Testing
@_spi(Benchmark) @testable import HotMicPlayer

@Suite("Atomic playlists")
struct PlayerPlaylistTests {
    private func clip(_ id: String) -> HMMediaItem { HMMediaItem(id: id, url: URL(string: "https://example.com/\(id).mp4")!) }

    @Test("Every edit preserves current identity and correct order; removal adjusts index")
    func operations() throws {
        var list = HMPlaylistState()
        try list.replaceAll([clip("a"), clip("b"), clip("c")], startAt: 1)
        try list.replaceUpcoming([clip("d")]); #expect(list.items.map(\.id) == ["a", "b", "d"])
        try list.insertNext([clip("e"), clip("f")]); #expect(list.items.map(\.id) == ["a", "b", "e", "f", "d"])
        try list.append([clip("g")]); #expect(list.current?.id == "b")
        list.remove(ids: ["a"]); #expect(list.index == 0); #expect(list.current?.id == "b")
        list.remove(ids: ["b", "e"]); #expect(list.current?.id == "f")
        list.index = 2; list.remove(ids: ["g"]); #expect(list.current?.id == "d")
        list.remove(ids: ["f", "d"]); #expect(list.items.isEmpty); #expect(list.current == nil)
        try list.insertNext([clip("z")]); #expect(list.current?.id == "z")
    }
    @Test("Duplicates, empty IDs and invalid start indices reject the whole edit")
    func rejectsAtomically() throws {
        var list = HMPlaylistState(); try list.replaceAll([clip("a"), clip("b")], startAt: 0)
        for operation in 0..<5 {
            do {
                switch operation {
                case 0: try list.append([clip("x"), clip("a")])
                case 1: try list.insertNext([clip("x"), clip("x")])
                case 2: try list.replaceUpcoming([clip("a")])
                case 3: try list.replaceAll([clip("x")], startAt: 5)
                default: try list.append([clip("")])
                }
                Issue.record("Expected rejection")
            } catch { #expect(error is HMPlayerError) }
            #expect(list.items.map(\.id) == ["a", "b"]); #expect(list.index == 0)
        }
        try list.replaceUpcoming([clip("b")]); #expect(list.items.map(\.id) == ["a", "b"])
    }
    @Test("Prefetch recomputes immediately after rapid edits and respects boundaries")
    func windows() throws {
        var list = HMPlaylistState(); try list.replaceAll([clip("a"), clip("b"), clip("c"), clip("d")], startAt: 1)
        let offsets = [0] + HMPrefetchPolicy(ahead: 2, behind: 1).windowOffsets
        #expect(list.window(offsets: offsets).map(\.id) == ["b", "c", "a", "d"])
        try list.insertNext([clip("x")]); try list.replaceUpcoming([clip("y"), clip("z")])
        list.remove(ids: ["a"])
        #expect(list.current?.id == "b")
        #expect(list.window(offsets: offsets).map(\.id) == ["b", "y", "z"])
    }
}

@Suite("Reference resolution") @MainActor
struct PlayerResolverTests {
    actor Resolver: HMItemResolver {
        var calls = 0
        let slow: Bool
        init(slow: Bool = false) { self.slow = slow }
        func resolve(_ ref: HMMediaItem.Reference) async throws -> HMResolvedItem {
            calls += 1
            try await Task.sleep(for: slow ? .seconds(60) : .milliseconds(5))
            return HMResolvedItem(url: URL(string: "https://example.com/\(ref.id).mp4")!, title: "Resolved")
        }
    }
    @Test("Concurrent callers share one resolution and completed results survive window changes")
    func deduplication() async throws {
        let store = HMResolutionStore(), resolver = Resolver(), item = HMMediaItem.reference("partner", id: "a")
        async let a = store.resolve(item, using: resolver)
        async let b = store.resolve(item, using: resolver)
        let (first, second) = try await (a, b)
        #expect(first == second); #expect(first.title == "Resolved"); #expect(await resolver.calls == 1)
        store.retain([])
        #expect(try await store.resolve(item, using: resolver) == first); #expect(await resolver.calls == 1)
    }
    @Test("Leaving the window cancels pending work and a missing resolver is a recoverable error")
    func cancellation() async throws {
        let store = HMResolutionStore(), resolver = Resolver(slow: true), item = HMMediaItem.reference("partner", id: "a")
        let waiter = Task { try await store.resolve(item, using: resolver) }
        let deadline = Date().addingTimeInterval(1)
        while await resolver.calls == 0, Date() < deadline { await Task.yield() }
        #expect(await resolver.calls == 1)
        store.retain([])
        do { _ = try await waiter.value; Issue.record("Cancelled work returned a result") } catch { #expect(error is CancellationError) }
        #expect(store.cached(item) == nil)
        do { _ = try await store.resolve(item, using: nil); Issue.record("Reference needs resolver") }
        catch { #expect(error as? HMPlayerError == .missingResolver) }
    }
}

@Suite("Review regressions")
struct PlayerReviewTests {
    private func item(_ id: String, path: String? = nil) -> HMMediaItem {
        HMMediaItem(id: id, url: URL(string: "https://example.com/\(path ?? id).mp4")!)
    }
    @Test("Appends and tail edits keep a move by ID; moved or removed endpoints invalidate")
    func pageIdentity() throws {
        let old = ["a", "b", "c", "d"]
        #expect(HMPagePosition.survives(old: old, new: old + ["e"], current: "b", destination: "c"))
        #expect(HMPagePosition.survives(old: old, new: ["a", "b", "c", "x"], current: "b", destination: "c"))
        #expect(!HMPagePosition.survives(old: old, new: ["a", "b", "x", "c"], current: "b", destination: "c"))
        #expect(!HMPagePosition.survives(old: old, new: ["b", "c", "d"], current: "b", destination: "c"))
        #expect(!HMPagePosition.survives(old: old, new: ["a", "b", "d"], current: "b", destination: "c"))
    }
    @Test("Overlapping source pages keep new entries in order, while partner duplicates still reject")
    func overlappingPages() throws {
        var list = HMPlaylistState(); try list.replaceAll([item("a")], startAt: 0)
        let page = list.filterSourcePage([item("a", path: "changed"), item("b"), item("b"), item("c")])
        #expect(page.items.map(\.id) == ["b", "c"]); #expect(page.duplicates == ["a", "b"])
        try list.append(page.items)
        #expect(list.items.map(\.id) == ["a", "b", "c"])
        #expect(list.filterSourcePage([item("a"), item("b")]).items.isEmpty)
        #expect(throws: HMPlayerError.duplicateID("a")) { try list.append([item("a")]) }
    }
    @Test("No-op edits and outside-window appends keep equality; same ID with new media changes identity")
    func windowIdentity() throws {
        var list = HMPlaylistState(); try list.replaceAll([item("a"), item("b"), item("c")], startAt: 0)
        let original = list, window = list.window(offsets: [0, 1])
        try list.append([]); try list.insertNext([]); list.remove(ids: ["unknown"])
        #expect(list == original)
        try list.append([item("d")]); #expect(list.window(offsets: [0, 1]) == window)
        try list.replaceUpcoming([item("b", path: "replacement"), item("c")])
        #expect(list.window(offsets: [0, 1]) != window)
        #expect(list.current == original.current)
    }
    @Test("Resolution retry budget is bounded, backs off, and resets for activation")
    func backoff() {
        var retry = HMResolutionRetry()
        retry.failed(at: 10); #expect(!retry.canRetry(at: 10.9)); #expect(retry.canRetry(at: 11))
        retry.failed(at: 11); #expect(retry.nextAttempt == 13)
        retry.failed(at: 13); #expect(!retry.canRetry(at: 100))
        retry = HMResolutionRetry(); #expect(retry.canRetry(at: 0))
    }
    @Test("Only the benchmark record owns configuration Codable, preserving the complete fingerprint")
    func benchmarkCoding() throws {
        var c = HMPlayerConfiguration.highQuality
        c.lowWaterMark = 7; c.volatileSigningQueryParameters = ["token"]
        let data = try JSONEncoder().encode(c.benchmarkRecord)
        let restored = try JSONDecoder().decode(HMPlayerConfiguration.BenchmarkRecord.self, from: data).configuration
        #expect(restored.fingerprint == c.fingerprint)
    }
    actor RecoveringResolver: HMItemResolver {
        var calls = 0
        var priority: TaskPriority?
        func resolve(_ ref: HMMediaItem.Reference) async throws -> HMResolvedItem {
            calls += 1
            if calls == 1 { throw HMPlayerError.resolution("Transient") }
            try await Task.sleep(for: .milliseconds(100))
            priority = Task.currentPriority
            return HMResolvedItem(url: URL(string: "https://example.com/recovered.mp4")!)
        }
    }
    @Test("A failed resolution can retry and utility work promotes without a second resolver call") @MainActor
    func retryAndPromotion() async throws {
        let store = HMResolutionStore(), resolver = RecoveringResolver(), entry = HMMediaItem.reference("partner", id: "retry")
        do { _ = try await store.resolve(entry, using: resolver); Issue.record("Expected transient failure") } catch { }
        let waiter = Task(priority: .utility) { try await store.resolve(entry, using: resolver) }
        while await resolver.calls < 2 { await Task.yield() }
        store.promote(entry)
        _ = try await waiter.value
        #expect(await resolver.calls == 2)
        #expect(await resolver.priority == .userInitiated)
    }
    @Test("Rejected HEAD falls back to a two-byte GET and retains metadata") @MainActor
    func formatFallback() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FormatProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let value = HMResolvedItem(url: URL(string: "https://unit-format.test/media")!, title: "Preserved", duration: 42)
        let result = try await HMResolutionStore.detectFormat(value, session: session)
        #expect(result.format == .hls); #expect(result.title == "Preserved"); #expect(result.duration == 42)
    }
}

private final class FormatProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "unit-format.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let head = request.httpMethod == "HEAD"
        if !head { #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-1") }
        let response = HTTPURLResponse(url: request.url!, statusCode: head ? 403 : 206, httpVersion: nil,
            headerFields: ["Content-Type": "application/vnd.apple.mpegurl", "Content-Length": "2"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !head { client?.urlProtocol(self, didLoad: Data("#E".utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

#if canImport(AVFoundation) && !os(macOS)
import AVFoundation

@Suite("Native review regressions") @MainActor
struct PlayerNativeReviewTests {
    private func item(_ id: String, path: String? = nil) -> HMMediaItem {
        HMMediaItem(id: id, url: URL(fileURLWithPath: "/tmp/hotmic-review-\(path ?? id).mp4"))
    }
    @Test("No-op operations are silent and animated requests survive only unchanged endpoint positions")
    func mutations() {
        let player = HMPlayer(); player.isFeedVisible = false
        defer { player.teardown() }
        player.replaceAll([item("a"), item("b"), item("c"), item("d")], startAt: 1)
        player.requestPage(at: 2)
        let request = player.pageRequestID, revision = player.playlistRevision, event = player.lastEvent
        player.append([]); player.insertNext([]); player.remove(ids: ["unknown"])
        #expect(player.playlistRevision == revision); #expect(player.lastEvent == event)
        #expect(player.pageRequestID == request)
        player.append([item("e")]); #expect(player.requestedPageID == "c"); #expect(player.pageRequestID == request)
        player.replaceUpcoming([item("c"), item("x")]); #expect(player.requestedPageID == "c")
        player.insertNext([item("z")]); #expect(player.requestedPageID == nil)
    }
    actor Source: HMPlaylistSource {
        var requests: [String] = []
        var release: CheckedContinuation<Void, Never>?
        let a: HMMediaItem, b: HMMediaItem
        init(a: HMMediaItem, b: HMMediaItem) { self.a = a; self.b = b }
        func loadPage(cursor: String?) async throws -> HMPlaylistPage {
            requests.append(cursor ?? "nil")
            switch cursor {
            case nil:
                await withCheckedContinuation { release = $0 }
                try Task.checkCancellation()
                return HMPlaylistPage(items: [a, b, b], nextCursor: "two")
            case "two": return HMPlaylistPage(items: [a, b], nextCursor: "three")
            default: return HMPlaylistPage(items: [], nextCursor: nil)
            }
        }
        func resume() { release?.resume(); release = nil }
    }
    @Test("An edit during automatic paging keeps one fetch; overlapping and all-duplicate pages advance")
    func sourceMerge() async throws {
        let player = HMPlayer(); player.isFeedVisible = false
        defer { player.teardown() }
        let source = Source(a: item("a"), b: item("b"))
        player.playlistSource = source
        player.replaceAll([item("a")])
        let deadline = Date().addingTimeInterval(3)
        while await source.requests.isEmpty, Date() < deadline { await Task.yield() }
        player.append([item("partner")])
        await source.resume()
        while player.hasMoreContent, Date() < deadline { await Task.yield() }
        #expect(await source.requests == ["nil", "two", "three"])
        #expect(player.items.map(\.id) == ["a", "partner", "b"])
        #expect(!player.hasMoreContent)
        #expect(player.playlistRevision == 3) // initial, partner edit, one unique source entry
    }
    @Test("Pool recycles a reused ID with changed media and retains an unchanged next item")
    func mediaIdentity() {
        let pool = HMPlayerPool()
        let old = item("next"), replacement = item("next", path: "new-media")
        let node = pool.node(for: old, protecting: [])
        #expect(pool.existingNode(for: replacement) == nil)
        pool.trim(keeping: [old]); #expect(pool.existingNode(for: old) === node)
        pool.trim(keeping: [replacement]); #expect(pool.busyCount == 0)
        let replaced = pool.node(for: replacement, protecting: [])
        #expect(replaced.item == replacement)
        #expect((replaced.player.currentItem?.asset as? AVURLAsset)?.url == replacement.url)
        pool.releaseAll()
    }
    @Test("Routes compare whole items; listener re-arms on use and publishes only a healthy port")
    func routesAndRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HotMic-review-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = try HMCacheTransport(configuration: .default, directory: directory)
        let old = HMMediaItem(id: "same", url: URL(string: "https://example.com/old.mp4")!)
        let new = HMMediaItem(id: "same", url: URL(string: "https://example.com/new.mp4")!)
        #expect(await transport.start())
        transport.state.prune(keeping: [old])
        let route = transport.url(for: old)!
        #expect(route.host == "127.0.0.1")
        transport.state.prune(keeping: [new])
        #expect(transport.state.allURLs().isEmpty)
        await transport.interruptListenerForTesting()
        let deadline = Date().addingTimeInterval(3)
        while transport.state.port != 0, Date() < deadline { await Task.yield() }
        #expect(transport.state.port == 0)
        #expect(transport.url(for: new) == new.url) // safe direct fallback while checking health
        while transport.state.port == 0, Date() < deadline { await Task.yield() }
        #expect(transport.state.port != 0)
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(transport.state.port)/health")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(transport.url(for: new)?.host == "127.0.0.1")
        _ = await transport.finish()
    }
}
#endif

@Suite("Paging retry policy")
struct PlayerPagingPolicyTests {
    @Test("Four failures exhaust paging with bounded exponential waits; reset restores eligibility")
    func budget() {
        var retry = HMPagingRetry()
        for (now, delay) in [(10.0, 1.0), (11, 2), (13, 4)] {
            retry.failed(at: now)
            #expect(retry.nextAttempt == now + delay)
            #expect(!retry.canRetry(at: now + delay - 0.01))
            #expect(retry.canRetry(at: now + delay))
        }
        retry.failed(at: 17); #expect(retry.exhausted); #expect(!retry.canRetry(at: 100))
        retry = HMPagingRetry(); #expect(retry.canRetry(at: 0))
        #expect(HMPlaybackEvent.Kind(rawValue: "transfer") == .transfer)
        #expect(HMPlaybackEvent.Kind(rawValue: "runEnd")?.rawValue == "runEnd")
        #expect(HMPlaybackEvent.Kind(rawValue: "unknown") == nil)
    }
}

#if canImport(AVFoundation) && !os(macOS)
@Suite("Native paging retry regressions") @MainActor
struct PlayerPagingRetryTests {
    actor FailingSource: HMPlaylistSource {
        var calls = 0
        let rejected: Bool
        init(rejected: Bool) { self.rejected = rejected }
        func loadPage(cursor: String?) async throws -> HMPlaylistPage {
            calls += 1
            if rejected { return HMPlaylistPage(items: [HMMediaItem(id: "invalid", url: URL(string: "ftp://example.com/file.mp4")!)], nextCursor: "bad") }
            throw URLError(.notConnectedToInternet)
        }
    }
    @Test("Thrown and rejected pages back off, emit one error per attempt, cap, and reset", arguments: [false, true])
    func failures(rejected: Bool) async throws {
        let player = HMPlayer(configuration: HMPlayerConfiguration(managesAudioSession: false)); player.isFeedVisible = false
        let source = FailingSource(rejected: rejected)
        var errors = 0
        let events = player.events
        let consumer = Task { for await event in events { if case .error = event { errors += 1 } } }
        defer { player.teardown(); consumer.cancel() }
        player.replaceAll([.reference("test", id: "a"), .reference("test", id: "b")])
        player.playlistSource = source
        await player.loadNextPage()
        #expect(await source.calls == 1)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await source.calls == 1); #expect(errors == 1)
        let deadline = Date().addingTimeInterval(9)
        while await source.calls < 4, Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        #expect(await source.calls == 4)
        try await Task.sleep(for: .milliseconds(200))
        #expect(errors == 4); #expect(!player.isLoadingPage); #expect(player.hasMoreContent)
        // start and unrelated edits must not reset the exhausted budget.
        await player.start(); player.append([.reference("test", id: "c")])
        try await Task.sleep(for: .milliseconds(100))
        #expect(await source.calls == 4)
        player.next()
        while await source.calls < 5, Date() < deadline { await Task.yield() }
        #expect(await source.calls == 5)
        while player.isLoadingPage, Date() < deadline { await Task.yield() }
        await player.loadNextPage()
        #expect(await source.calls == 6)
        try await Task.sleep(for: .milliseconds(25)); #expect(errors == 6)
    }
    @Test("Public audio ownership opt-out survives playback, foreground resume and teardown")
    func audioOwnership() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.ambient, mode: .default)
        let player = HMPlayer(configuration: HMPlayerConfiguration(loops: false, startsMuted: true, managesAudioSession: false))
        #expect(player.isMuted); #expect(!player.configuration.loops)
        player.replaceAll([.reference("test", id: "owned-session")])
        await player.requestPlay(at: 0)
        #expect(session.category == .ambient)
        player.isFeedVisible = false; player.isFeedVisible = true
        #expect(session.category == .ambient)
        player.teardown()
        #expect(session.category == .ambient)
    }
    actor CursorSource: HMPlaylistSource {
        var requests: [String] = []
        var gate: CheckedContinuation<Void, Never>?
        func loadPage(cursor: String?) async throws -> HMPlaylistPage {
            requests.append(cursor ?? "nil")
            if requests.count == 2 { await withCheckedContinuation { gate = $0 } }
            return HMPlaylistPage(items: [.reference("test", id: "page-\(requests.count)", playlistID: "page-\(requests.count)")], nextCursor: "cursor-\(requests.count)")
        }
        func resume() { gate?.resume(); gate = nil }
    }
    @Test("replaceAll resets a settled cursor and discards an in-flight old page without cancelling it")
    func cursorReset() async throws {
        let player = HMPlayer(configuration: HMPlayerConfiguration(managesAudioSession: false)); player.isFeedVisible = false
        defer { player.teardown() }
        var configuration = player.configuration; configuration.lowWaterMark = 0; player.configuration = configuration
        // Stay outside the automatic window to drive one explicit page at a time.
        let seeds: [HMMediaItem] = [.reference("test", id: "a", playlistID: "a"), .reference("test", id: "b", playlistID: "b")]
        player.replaceAll(seeds)
        let source = CursorSource(); player.playlistSource = source
        await player.loadNextPage()
        let pending = Task { await player.loadNextPage() }
        let deadline = Date().addingTimeInterval(2)
        while await source.requests.count < 2, Date() < deadline { await Task.yield() }
        #expect(await source.requests == ["nil", "cursor-1"])
        #expect(!player.replaceAll(seeds, startAt: 99)) // invalid replacement leaves cursor intact
        player.replaceAll(seeds)
        await source.resume(); await pending.value
        #expect(player.items.map(\.id) == ["a", "b"])
        await player.loadNextPage()
        #expect(await source.requests == ["nil", "cursor-1", "nil"])
        #expect(player.items.map(\.id) == ["a", "b", "page-3"])
        player.replaceAll(seeds); await player.loadNextPage()
        #expect(await source.requests.last == "nil")
    }
}
#endif
