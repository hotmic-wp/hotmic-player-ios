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
    @Test("Ranked reconciliation preserves history, skips replayed history, and applies missing-current policy", arguments: [HMRemovedCurrentPolicy.advanceNow, .finishThenAdvance])
    func rankedFeed(policy: HMRemovedCurrentPolicy) throws {
        var list = HMPlaylistState()
        try list.replaceAll([clip("a"), clip("b"), clip("c"), clip("d")], startAt: 1)
        try list.reconcile([clip("new-prefix"), clip("b"), clip("d"), clip("a"), clip("c")], policy: policy)
        #expect(list.items.map(\.id) == ["a", "b", "d", "c"])
        let before = list
        #expect(throws: HMPlayerError.duplicateID("ignored")) {
            try list.reconcile([clip("ignored"), clip("ignored"), clip("b")], policy: policy)
        }
        #expect(list == before)
        try list.reconcile([clip("a"), clip("x"), clip("d")], policy: policy)
        if policy == .finishThenAdvance {
            #expect(list.items.map(\.id) == ["a", "b", "x", "d"])
            #expect(list.current?.id == "b" && list.finishingID == "b")
            let replacement = HMMediaItem(id: "b", url: URL(string: "https://example.com/restarted.mp4")!)
            try list.reconcile([replacement, clip("x")], policy: policy)
            #expect(list.current?.source == clip("b").source)
            #expect(list.finishingID == "b")
            list.remove(ids: ["b"])
        }
        #expect(list.current?.id == "x")
        let nonempty = list
        try list.reconcile([], policy: policy)
        #expect(list == nonempty)
        try list.reconcile([clip("a")], policy: policy)
        if policy == .finishThenAdvance {
            #expect(list.current?.id == "x" && list.finishingID == "x")
            list.remove(ids: ["x"])
        }
        #expect(list.current == nil && list.items.map(\.id) == ["a"])
        #expect(list.window(offsets: [-1, 0, 1]).isEmpty)
        try list.reconcile([clip("a")], policy: policy)
        #expect(list.current == nil)
        try list.reconcile([clip("a"), clip("z")], policy: policy)
        #expect(list.items.map(\.id) == ["a", "z"] && list.current?.id == "z")
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
        let refreshed = HMMediaItem(id: item.id, source: item.source, title: "Latest", metadata: ["rank": "1"], aspectRatio: 16.0/9, presentation: .fitWithBlurredBackdrop)
        #expect(try await store.resolve(refreshed, using: resolver).title == "Latest")
        #expect(store.cached(refreshed)?.metadata == ["rank": "1"])
        #expect(store.cached(refreshed)?.aspectRatio == 16.0/9)
        #expect(store.cached(refreshed)?.presentation == .fitWithBlurredBackdrop)
        store.retain([])
        #expect(try await store.resolve(item, using: resolver) == first); #expect(await resolver.calls == 1)
    }
    actor MetadataResolver: HMItemResolver {
        var calls = 0
        func resolve(_ ref: HMMediaItem.Reference) async throws -> HMResolvedItem {
            calls += 1
            try await Task.sleep(for: .milliseconds(20))
            return HMResolvedItem(url: URL(string: "https://unit-format.test/media")!, poster: URL(string: "https://metadata-only.invalid/poster.jpg"))
        }
    }
    @Test("Far references resolve metadata without fetching media or probing format")
    func metadataTier() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FormatProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let store = HMResolutionStore(session: session), resolver = MetadataResolver(), entry = HMMediaItem.reference("partner", id: "far")
        let result = try await store.resolve(entry, using: resolver, metadataOnly: true)
        #expect(result.format == .auto && result.posterURL != nil)
        #expect(store.cached(entry) == nil)
        #expect(store.cached(entry, requireFormat: false) == result)
        #expect(try await store.resolve(entry, using: resolver, metadataOnly: true) == result)
        #expect(await resolver.calls == 1)
        let promoted = try await store.resolve(entry, using: resolver)
        #expect(promoted.format == .hls && promoted.posterURL == result.posterURL)
        #expect(await resolver.calls == 1)
        let concurrent = HMResolutionStore(session: session), shared = MetadataResolver()
        let metadata = Task { try await concurrent.resolve(entry, using: shared, metadataOnly: true) }
        await Task.yield()
        let media = Task { try await concurrent.resolve(entry, using: shared) }
        #expect(try await metadata.value.format == .auto)
        #expect(try await media.value.format == .hls)
        #expect(await shared.calls == 1)
        let cancellationStore = HMResolutionStore(), delayed = Resolver()
        let cancelled = Task { try await cancellationStore.resolve(entry, using: delayed) }
        let survivor = Task { try await cancellationStore.resolve(entry, using: delayed) }
        await Task.yield(); cancelled.cancel()
        #expect(try await survivor.value.url != nil)
        do { _ = try await cancelled.value; Issue.record("Cancelled waiter returned") } catch { #expect(error is CancellationError) }
        #expect(await delayed.calls == 1)

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
    @Test("Overlapping source pages keep new entries in order")
    func overlappingPages() throws {
        var list = HMPlaylistState(); try list.replaceAll([item("a")], startAt: 0)
        let page = list.filterSourcePage([item("a", path: "changed"), item("b"), item("b"), item("c")])
        #expect(page.items.map(\.id) == ["b", "c"]); #expect(page.duplicates == ["a", "b"])
        try list.append(page.items)
        #expect(list.items.map(\.id) == ["a", "b", "c"])
        #expect(list.filterSourcePage([item("a"), item("b")]).items.isEmpty)
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
        c.failedItemPolicy = .stay; c.removedCurrentPolicy = .finishThenAdvance
        c.lowWaterMark = 7; c.volatileSigningQueryParameters = ["token"]
        c.presentation = .fitWithColor; c.aspectRatioTolerance = 0.2
        c.backdropColor = HMVideoBackdropColor(red: 0.1, green: 0.2, blue: 0.3)
        c.followsDeviceRotation = true; c.allowsBackgroundAudio = true
        let data = try JSONEncoder().encode(c.benchmarkRecord)
        let restored = try JSONDecoder().decode(HMPlayerConfiguration.BenchmarkRecord.self, from: data).configuration
        #expect(restored.fingerprint == c.fingerprint)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(legacy["failedItemPolicy"] as? String == "stay")
        legacy.removeValue(forKey: "failedItemPolicy"); legacy.removeValue(forKey: "removedCurrentPolicy")
        for key in ["presentation", "aspectRatioTolerance", "backdropColor", "followsDeviceRotation", "allowsBackgroundAudio"] { legacy.removeValue(forKey: key) }
        let oldData = try JSONSerialization.data(withJSONObject: legacy)
        #expect(try JSONDecoder().decode(HMPlayerConfiguration.BenchmarkRecord.self, from: oldData).configuration.removedCurrentPolicy == .advanceNow)
        let old = try JSONDecoder().decode(HMPlayerConfiguration.BenchmarkRecord.self, from: oldData).configuration
        #expect(old.failedItemPolicy == .skip && old.presentation == .automatic)
        #expect(old.aspectRatioTolerance == 0.25 && !old.followsDeviceRotation && !old.allowsBackgroundAudio)
        // The aggregate DTO is a distinct allowlist, never the benchmark fingerprint.
        c.volatileSigningQueryParameters = ["PRIVATE_PROPERTY_SENTINEL"]
        let reported = try #require(HMDiagnosticsConfig(c))
        let aggregate = HMDiagnosticsAggregate(config: reported, rate: 0.01)
        let wire = try JSONEncoder().encode(aggregate)
        let object = try #require(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        #expect(Set(object.keys) == Set(["schema_version", "sdk_version", "os_version", "hardware_model", "sample_rate", "window_duration_ms", "config", "playback", "startup_buckets", "moving_start_buckets", "stalls"]))
        #expect(wire.count <= 8192 && !String(decoding: wire, as: UTF8.self).contains("PRIVATE_"))
        #expect(reported.startup_bps == 0)
        c.startupPeakBitRate = 1_600_000.6
        #expect(HMDiagnosticsConfig(c)?.startup_bps == 1_600_001)
        for invalid in [Double.nan, .infinity, -1, 1_000_000_001] {
            c.startupPeakBitRate = invalid; #expect(HMDiagnosticsConfig(c) == nil)
        }
        c.startupPeakBitRate = 0; c.prefetch.secondsPerItem = 0.0000001
        #expect(HMDiagnosticsConfig(c)?.entry_ms == 1)
        c.prefetch.secondsPerItem = nil; #expect(HMDiagnosticsConfig(c)?.entry_ms == 0)
        c.prefetch.secondsPerItem = -1
        #expect(HMDiagnosticsConfig(c)?.entry_bytes == 0 && HMDiagnosticsConfig(c)?.entry_ms == 0)
        c.prefetch.secondsPerItem = 60.0001; #expect(HMDiagnosticsConfig(c) == nil)
        c.prefetch.secondsPerItem = .nan; #expect(HMDiagnosticsConfig(c) == nil)
        c.prefetch.secondsPerItem = 4; c.prefetch.bytesPerItem = 100_000_000
        #expect(HMDiagnosticsConfig(c) == nil)
        c.prefetch.bytesPerItem = 0
        #expect(HMDiagnosticsConfig(c)?.entry_bytes == 0 && HMDiagnosticsConfig(c)?.entry_ms == 0)
        for (ms, index) in [(0.0,0),(99.99,0),(100,1),(150,2),(250,3),(500,4),(1000,5),(2000,6),(5000,7)] {
            #expect(HMDiagnosticsAggregate.bucket(ms) == index)
        }
        #expect(HMDiagnosticsAggregate.bucket(.nan) == nil)
        #expect(HMDiagnosticsAggregate.bucket(-1) == nil)
        for raw in ["http://example.com", "https://name@example.com", "https://example.com?a=1", "https://example.com#private", "http://127.0.0.1.example.com"] {
            #expect(HMPlayerDiagnosticsConfiguration(baseURL: URL(string: raw)!, appKey: "synthetic").endpoint == nil)
        }
        for percent in [0.0, -1, 101, .nan, .infinity, 0.00001] {
            #expect(HMPlayerDiagnosticsConfiguration(baseURL: URL(string: "https://example.com")!, appKey: "synthetic", samplingPercent: percent).endpoint == nil)
        }
        #expect(HMPlayerDiagnosticsConfiguration(baseURL: URL(string: "http://127.0.0.1")!, appKey: "synthetic").endpoint != nil)

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
        defer { waiter.cancel() }
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(5))
        while await resolver.calls < 2, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await resolver.calls == 2, "Utility resolution did not start within five seconds")
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
        let store = HMResolutionStore(session: session)
        store.configure(signingParameters: ["token"])
        let old = HMMediaItem(id: "signed", url: URL(string: "https://unit-format.test/media?token=old")!)
        _ = try await store.resolve(old, using: nil)
        let latest = HMMediaItem(id: old.id, url: URL(string: "https://unit-format.test/media?token=new")!, title: "Latest")
        #expect(store.cached(latest)?.url == latest.url && store.cached(latest)?.title == "Latest")
        #expect(store.cached(latest)?.format == .hls)
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
import Network
import Darwin

/// Flush receipts immediately so a stuck native call leaves its last completed phase in CI logs.
func nativeTestPhase(_ phase: String) {
    FileHandle.standardError.write(Data("[native-test] \(ProcessInfo.processInfo.systemUptime) \(phase)\n".utf8))
}
#if canImport(UIKit)
import UIKit
import SwiftUI
#endif

@Suite("Native review regressions") @MainActor
struct PlayerNativeReviewTests {
    @Test("Warm track detection respects camera transforms before activation", arguments: [false, true])
    func warmDisplayAspect(rotated: Bool) async throws {
        if !rotated { try await verifyFixtureTermination() }
        let url = try await videoFixture(rotated: rotated)
        defer { try? FileManager.default.removeItem(at: url) }
        let node = HMPlayerNode(id: "aspect", configuration: HMPlayerConfiguration(managesAudioSession: false))
        defer { node.release() }
        node.warm(with: HMMediaItem(id: "camera", url: url, aspectRatio: 1)) // intentionally wrong hint
        node.updateMetadata(HMMediaItem(id: "camera", url: url, aspectRatio: 0.75))
        #expect(node.snapshot.aspectRatio == 0.75) // hints can change before track loading completes
        let expected = rotated ? 9.0/16 : 16.0/9
        let deadline = Date().addingTimeInterval(3)
        while abs((node.snapshot.aspectRatio ?? 0) - expected) > 0.001, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!node.isActive)
        let outputs = node.player.currentItem?.outputs.count
        node.captureBackdropPoster() // warm capture must not consume the startup output
        #expect(node.backdropPoster == nil && node.player.currentItem?.outputs.count == outputs)
        let point = CGPoint(x: 1, y: 0).applying(HMBackdropImage.displayTransform(CGAffineTransform(rotationAngle: .pi / 2)))
        #expect(abs(point.x) < 0.001 && abs(point.y + 1) < 0.001)
        #expect(abs((node.snapshot.aspectRatio ?? 0) - expected) < 0.001)
        node.updateMetadata(HMMediaItem(id: "camera", url: url, aspectRatio: 1))
        #expect(abs((node.snapshot.aspectRatio ?? 0) - expected) < 0.001) // decoded size wins
        let replacement = HMMediaItem(id: "new", url: URL(fileURLWithPath: "/missing-214.mp4"), aspectRatio: 0.75)
        node.warm(with: replacement)
        try await Task.sleep(for: .milliseconds(50))
        #expect(node.snapshot.aspectRatio == 0.75) // stale loads must not overwrite a recycled node
    }

    @Test("Fullscreen and policy changes preserve the native item, activation and feed index")
    func fullscreenContinuity() async throws {
        let url = try await videoFixture(rotated: false)
        defer { try? FileManager.default.removeItem(at: url) }
        var configuration = HMPlayerConfiguration(managesAudioSession: false, failedItemPolicy: .stay)
        configuration.followsDeviceRotation = true
        let player = HMPlayer(configuration: configuration); player.isFeedVisible = false
        defer { player.teardown() }
        let entry = HMMediaItem(id: "landscape", url: url, aspectRatio: 16.0/9)
        player.replaceAll([entry, HMMediaItem(id: "next", url: url)])
        let node = player.pool.node(for: entry, protecting: [])
        node.activate()
        let native = node.player.currentItem, generation = node.assignmentGeneration, activation = node.snapshot.activationID
        player.enterFullscreen(); #expect(player.isFullscreen)
        player.requestPage(at: 1); player.commitPage(toID: "next", requestedAt: 0)
        #expect(player.activeIndex == 0 && player.requestedPageID == nil)
        for policy in [HMVideoPresentation.fill, .fit, .fitWithBlurredBackdrop, .fitWithColor, .automatic] {
            player.configuration.presentation = policy
            #expect(node.player.currentItem === native && node.assignmentGeneration == generation)
        }
        let overridden = HMMediaItem(id: entry.id, url: url, aspectRatio: 16.0/9, presentation: .fill)
        player.replaceAll([overridden, HMMediaItem(id: "next", url: url)])
        player.configuration.presentation = .fit
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        #expect(player.videoFrame(for: overridden, in: bounds) == bounds) // item override wins
        #expect(node.player.currentItem === native && node.assignmentGeneration == generation)
        player.exitFullscreen(); #expect(!player.isFullscreen)
        player.deviceRotated(isLandscape: true); #expect(player.isFullscreen)
        player.deviceRotated(isLandscape: false); #expect(!player.isFullscreen)
        #expect(node.snapshot.activationID == activation && player.activeIndex == 0)
        #expect(node.snapshot.stallCount == 0)
        player.configuration.followsDeviceRotation = false
        player.deviceRotated(isLandscape: true); #expect(!player.isFullscreen)
        #if os(iOS)
        #expect(HMFullscreenPresenterController.presentationOrientation(current: .portrait, device: .landscapeLeft,
            landscapeItem: true, supported: .portrait) == .portrait)
        #expect(HMFullscreenPresenterController.presentationOrientation(current: .portrait, device: .landscapeLeft,
            landscapeItem: true, supported: [.portrait, .landscapeLeft]) == .landscapeLeft)
        let owner = HMFullscreenPresenterController(player: player)
        let duplicate = HMFullscreenPresenterController(player: player)
        player.fullscreenPresenter = owner; player.enterFullscreen()
        duplicate.stop()
        #expect(player.isFullscreen && player.fullscreenPresenter === owner)
        owner.stop(); #expect(!player.isFullscreen && player.fullscreenPresenter == nil)
        #endif
        player.attachInline(); #expect(player.isFeedVisible)
        player.pause(); player.detachInline(); #expect(!player.isFeedVisible)
        player.attachInline(); #expect(player.isFeedVisible && node.player.rate == 0)
        player.detachInline()
    }

    @Test("Fullscreen failure skipping resumes on exit for inline and mounted feed", arguments: [false, true])
    func fullscreenFailure(feed: Bool) async throws {
        let player = HMPlayer(configuration: HMPlayerConfiguration(managesAudioSession: false))
        player.isFeedVisible = false
        defer { player.teardown() }
        let a = item("failed-fullscreen"), b = item("next-fullscreen")
        player.replaceAll([a, b])
        if feed { player.attachFeed(); player.isFeedVisible = false }
        player.enterFullscreen()
        player.pool.onEvent?(HMPlaybackEvent(kind: .error, itemID: a.id), a)
        for _ in 0..<10 { await Task.yield() }
        #expect(player.currentItem?.id == a.id && player.requestedPageID == nil)
        player.exitFullscreen()
        let deadline = Date().addingTimeInterval(1)
        while player.currentItem?.id == a.id && player.requestedPageID == nil, Date() < deadline { await Task.yield() }
        if feed {
            #expect(player.requestedPageID == b.id)
            player.commitPage(toID: b.id, requestedAt: 0)
            player.detachFeed()
        }
        #expect(player.currentItem?.id == b.id)
    }

    #if canImport(UIKit)
    @Test("A real drag ends fullscreen geometry restoration immediately")
    func quickSwipeAfterFullscreen() {
        let reference = HMScrollViewReference()
        var committed: String?
        let coordinator = HMPageCommitProbe.Coordinator(commit: { id, _ in committed = id }, reference: reference, interaction: { _ in })
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        scroll.contentSize = CGSize(width: 390, height: 1688)
        coordinator.observe(scroll); coordinator.reconcile(items: ["a", "b"], current: "a")
        coordinator.isSuspended = true; coordinator.isSuspended = false
        #expect(reference.isRestoringFullscreen)
        coordinator.scrollViewWillBeginDragging(scroll)
        #expect(!reference.isRestoringFullscreen)
        scroll.contentOffset.y = 844
        coordinator.scrollViewDidEndDragging(scroll, willDecelerate: false)
        #expect(committed == "b")
        coordinator.fallback?.cancel()
        var reports: [(String, HMPageCommit)] = []
        let known = HMPageCommitProbe.Coordinator(commit: { reports.append(($0, $1)) }, reference: HMScrollViewReference(), interaction: { _ in })
        let inset = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        inset.contentInset.top = 20; inset.contentSize = CGSize(width: 390, height: 2400)
        inset.contentOffset.y = -20
        known.observe(inset); known.reconcile(items: ["a", "b", "c"], current: "a")
        known.scrollViewWillBeginDragging(inset)
        var target = CGPoint(x: 0, y: -20)
        known.scrollViewWillEndDragging(inset, withVelocity: .zero, targetContentOffset: &target)
        #expect(reports.isEmpty) // A cancelled return-to-origin never activates a neighbour at lift.
        known.scrollViewDidEndDragging(inset, willDecelerate: false)
        #expect(reports.last?.0 == "a" && reports.last?.1.source == .settle)
        reports.removeAll(); known.scrollViewWillBeginDragging(inset)
        target.y = 1580 // Multi-page target with adjusted top inset.
        known.scrollViewWillEndDragging(inset, withVelocity: CGPoint(x: 0, y: 9), targetContentOffset: &target)
        #expect(reports.count == 1 && reports[0].0 == "c" && reports[0].1.source == .lift)
        known.reconcile(items: ["a", "b", "c"], current: "c"); inset.contentOffset.y = 1580
        known.scrollViewDidEndDecelerating(inset)
        #expect(reports.last?.0 == "c" && reports.last?.1.correction == nil)
        reports.removeAll(); known.scrollViewWillBeginDragging(inset)
        target.y = 900 // Fractional/unknown target: never use the supplied velocity to guess.
        known.scrollViewWillEndDragging(inset, withVelocity: CGPoint(x: 0, y: -99), targetContentOffset: &target)
        #expect(reports.isEmpty)
        inset.bounds.size.height = 700; target.y = 680
        known.scrollViewWillEndDragging(inset, withVelocity: .zero, targetContentOffset: &target)
        #expect(reports.isEmpty) // Resize keeps the current-ID restoration guard.
        known.fallback?.cancel(); known.cancelRequest()
    }
    #endif

    #if canImport(UIKit)
    @Test("Repeated UIKit squeeze updates retain node, native item, surface and layer; custom actions respect the ad gate")
    func squeezeIdentityAndAccessibility() async throws {
        let player = HMPlayer(configuration: HMPlayerConfiguration(managesAudioSession: false, failedItemPolicy: .stay))
        player.isFeedVisible = false
        defer { player.teardown() }
        let url = try await videoFixture(rotated: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let item = HMMediaItem(id: "identity", url: url, aspectRatio: 9.0/16)
        player.replaceAll([item])
        let node = player.pool.node(for: item, protecting: [])
        node.activate()
        let native = node.player.currentItem, generation = node.assignmentGeneration, activation = node.snapshot.activationID
        let controller = HMPlayerViewController(player: player, aspectRatio: nil)
        #expect(!controller.extendsUnderSafeArea)
        controller.extendsUnderSafeArea = true
        var reportedFrames: [CGRect] = []
        controller.onVideoFrameChange = { reportedFrames.append($0) }
        let inlineHooks = HMSurfaceHooks(layout: HMVideoLayout(contentInsets: HMVideoInsets(bottom: 88), squeezeTarget: CGRect(x: 0, y: 60, width: 390, height: 200)), excludedRegions: [CGRect(x: 0, y: 0, width: 100, height: 100)])
        #expect(inlineHooks.forFullscreen.layout == HMVideoLayout())
        #expect(inlineHooks.forFullscreen.excludedRegions.isEmpty)
        var customHooks = inlineHooks
        customHooks.fullscreenLayout = HMVideoLayout(contentInsets: HMVideoInsets(top: 20))
        #expect(customHooks.forFullscreen.layout.contentInsets.top == 20)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller; window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        var fires: [CGPoint] = [], taps = 0
        controller.onTap = { taps += 1 }
        controller.onDoubleTap = { fires.append($0) }
        func descendants<T: UIView>(_ view: UIView, _ type: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) }
        }
        func settle() async throws { controller.view.setNeedsLayout(); controller.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
        try await settle()
        let deadline = Date().addingTimeInterval(3)
        while !node.snapshot.isFrameReady, Date() < deadline { try await settle() }
        try #require(node.snapshot.isFrameReady)
        // The unhosted unit runner has no visible app scene; rendered first-frame continuity
        // is verified in the Sample walkthrough. Preserve whatever metric exists here.
        let firstFrame = node.snapshot.timeToFirstFrame
        let surface = try #require(descendants(controller.view, HMVideoSurfaceView.self).first)
        controller.videoLayout = HMVideoLayout(contentInsets: HMVideoInsets(bottom: 88))
        for height in stride(from: 700, through: 200, by: -100) {
            controller.videoLayout.squeezeTarget = CGRect(x: 0, y: 60, width: 390, height: height)
            try await settle()
            #expect(descendants(controller.view, HMVideoSurfaceView.self).first === surface)
            #expect(node.player.currentItem === native && node.assignmentGeneration == generation)
            #expect(node.snapshot.activationID == activation && node.snapshot.timeToFirstFrame == firstFrame)
            #expect(node.snapshot.stallCount == 0)
            #expect(node.playerLayer.superlayer === surface.layer)
            let frame = controller.videoFrame
            #expect(frame.height > 0)
            #expect(frame.maxY <= CGFloat(height + 60) + 0.01) // UIKit coordinate conversion can round subpixel bounds.
        }
        player.configuration.presentation = .fit; try await settle()
        let gesture = try #require(descendants(controller.view, HMVideoGestureView.self).first)
        #expect(!gesture.acceptsTap(at: CGPoint(x: 20, y: 100), isDoubleTap: false))
        #expect(gesture.acceptsTap(at: CGPoint(x: 20, y: 100), isDoubleTap: true))
        #expect(gesture.videoElement.accessibilityLabel == "Video" && gesture.videoElement.accessibilityValue != nil)
        #expect(gesture.videoElement.accessibilityCustomActions?.map(\.name).contains("Fire") == true)
        let cachedActions = gesture.videoElement.accessibilityCustomActions ?? []
        controller.videoLayout.squeezeTarget?.origin.y += 1
        try await settle()
        #expect(zip(cachedActions, gesture.videoElement.accessibilityCustomActions ?? []).allSatisfy { $0 === $1 })
        #expect(reportedFrames.last == controller.videoFrame && reportedFrames.count >= 6)
        #expect(gesture.accessibilityActivate() && taps == 1 && fires.isEmpty)
        let action = try #require(gesture.videoElement.accessibilityCustomActions?.first { $0.name == "Fire" })
        #expect(action.actionHandler?(action) == true)
        #expect(fires == [CGPoint(x: gesture.videoFrame.midX, y: gesture.videoFrame.midY)])
        controller.excludedHitAreas = [CGRect(x: 0, y: 60, width: 100, height: 100)]
        try await settle()
        #expect(!gesture.point(inside: CGPoint(x: 50, y: 100), with: nil))
        #expect(!gesture.acceptsTap(at: CGPoint(x: 50, y: 100), isDoubleTap: true))
        player.pause(); try await settle()
        let playAction = try #require(gesture.videoElement.accessibilityCustomActions?.first { $0.name == "Play" })
        #expect(playAction.actionHandler?(playAction) == true)
        #expect(taps == 1) // Play/Pause remains reachable even with a host tap override.
        controller.isAdPlaying = true
        try await settle()
        #expect(!gesture.isAccessibilityElement && gesture.videoElement.accessibilityCustomActions?.isEmpty == true)
        #expect(!gesture.singleTap.isEnabled && !gesture.doubleTap.isEnabled && !gesture.accessibilityActivate())
        controller.isAdPlaying = false; controller.videoLayout.squeezeTarget = nil
        try await settle()
        #expect(gesture.singleTap.isEnabled && gesture.doubleTap.isEnabled)
        #expect(node.player.currentItem === native && node.assignmentGeneration == generation)

        // Exercise HMPlayer.configuration -> resize -> release -> synchronous viewEnd
        // with the current active node above the retained pool range.
        let shrinking = HMPlayer(configuration: HMPlayerConfiguration(strategy: .S2, poolSize: 2,
            prefetch: .init(ahead: 1, behind: 1), managesAudioSession: false, failedItemPolicy: .stay))
        defer { shrinking.teardown() }
        let filler = HMMediaItem(id: "retained-slot", url: url)
        let highItem = HMMediaItem(id: "high-current", url: url)
        shrinking.replaceAll([filler, highItem])
        let warmDeadline = Date().addingTimeInterval(3)
        while shrinking.pool.existingNode(for: highItem) == nil, Date() < warmDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let high = try #require(shrinking.pool.existingNode(for: highItem))
        try #require(high === shrinking.pool.nodes[1])
        shrinking.next()
        let activeDeadline = Date().addingTimeInterval(3)
        while !high.isActive, Date() < activeDeadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(shrinking.currentItem?.id == highItem.id && high.isActive)
        let highController = HMPlayerViewController(player: shrinking, aspectRatio: nil)
        window.rootViewController = highController
        highController.view.layoutIfNeeded()
        let frameDeadline = Date().addingTimeInterval(3)
        while !high.playerLayer.isReadyForDisplay, Date() < frameDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        // Native ready layer + existing display-boundary hook (the unhosted runner
        // may not deliver a scene display link); no synthetic metric/event injection.
        high.didDisplayFrame(activation: high.snapshot.activationID, at: ProcessInfo.processInfo.systemUptime)
        try #require(high.snapshot.timeToFirstFrame != nil)
        shrinking.setDiagnostics(.init(baseURL: URL(string: "http://127.0.0.1:9")!, appKey: "synthetic", samplingPercent: 100))
        shrinking.configuration.poolSize = 1
        #expect(shrinking.diagnosticsRecorder?.aggregate?.playback.ended_before_first_frame == 0)
        shrinking.configuration.poolSize = 2
        // The previous item remains resolved. Navigation synchronously activates it
        // in the new higher slot; shrink before a display boundary can run.
        shrinking.previous()
        let blankNode = try #require(shrinking.pool.existingNode(for: filler))
        try #require(blankNode === shrinking.pool.nodes[1] && blankNode.isActive)
        try #require(blankNode.snapshot.timeToFirstFrame == nil)
        shrinking.configuration.poolSize = 1
        #expect(shrinking.diagnosticsRecorder?.aggregate?.playback.ended_before_first_frame == 1)
    }
    #endif

    enum VideoFixtureError: Error { case timedOut, unexpectedCompletion }

    /// Small local encoded fixture; tests never depend on a network origin or checked-in video.
    /// The finish seam lets the existing native regression hold a real writer in `.writing`.
    func videoFixture(rotated: Bool, duration: TimeInterval = 1, finishTimeout: TimeInterval = 3,
                      finish: (AVAssetWriter) -> Void = { $0.finishWriting {} }) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hotmic-aspect-\(UUID()).mp4")
        let receiptID = UUID().uuidString.prefix(8)
        func phase(_ value: String) { nativeTestPhase("fixture=\(receiptID) rotated=\(rotated) duration=\(duration) \(value)") }
        phase("create before")
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: url) } }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        // Every throw, including Task.sleep cancellation, cancels native work before releasing ownership.
        defer {
            if !completed {
                phase("cancel before status=\(writer.status.rawValue)")
                writer.cancelWriting()
                phase("cancel after status=\(writer.status.rawValue)")
            }
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90])
        if rotated { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90])
        writer.add(input)
        try Task.checkCancellation()
        phase("start before")
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        phase("start after")
        var buffer: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, 160, 90, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(try #require(CVPixelBufferGetBaseAddress(pixels)), 64, CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        func ready() async throws {
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                try #require(writer.status == .writing)
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw VideoFixtureError.timedOut }
                try await Task.sleep(for: .milliseconds(1))
            }
            try Task.checkCancellation()
        }
        phase("append before")
        try await ready()
        try #require(adaptor.append(pixels, withPresentationTime: .zero))
        if duration > 1 {
            for frame in 1..<Int(duration * 10) {
                try await ready()
                try #require(adaptor.append(pixels, withPresentationTime: CMTime(seconds: Double(frame) / 10, preferredTimescale: 600)))
            }
        }
        phase("append after")
        phase("end-session before")
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
        input.markAsFinished()
        phase("end-session after")
        try Task.checkCancellation()
        phase("finish before")
        finish(writer)
        // Do not await the non-cooperative native completion or a task-group child.
        // Poll terminal status; timeout/cancellation synchronously cancels the owned writer above.
        let finishDeadline = ProcessInfo.processInfo.systemUptime + finishTimeout
        while writer.status == .writing {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < finishDeadline else { throw VideoFixtureError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
        try Task.checkCancellation()
        phase("finish after status=\(writer.status.rawValue)")
        try #require(writer.status == .completed)
        completed = true
        return url
    }

    /// A held finish must fail promptly and release real native work and its partial file.
    func verifyFixtureTermination() async throws {
        var held: AVAssetWriter?
        var heldAt: TimeInterval?
        do {
            let url = try await videoFixture(rotated: false, finishTimeout: 0.05, finish: {
                held = $0; heldAt = ProcessInfo.processInfo.systemUptime
            })
            try? FileManager.default.removeItem(at: url)
            throw VideoFixtureError.unexpectedCompletion
        } catch VideoFixtureError.timedOut { }
        let timedOut = try #require(held)
        let began = try #require(heldAt)
        #expect(timedOut.status == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: timedOut.outputURL.path))
        #expect(ProcessInfo.processInfo.systemUptime - began < 2)

        var cancelling: AVAssetWriter?
        let task = Task { try await videoFixture(rotated: false, finish: { cancelling = $0 }) }
        do {
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while cancelling == nil, ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let cancelled = try #require(cancelling)
            task.cancel()
            do {
                let url = try await task.value
                try? FileManager.default.removeItem(at: url)
                throw VideoFixtureError.unexpectedCompletion
            } catch is CancellationError { }
            #expect(cancelled.status == .cancelled)
            #expect(!FileManager.default.fileExists(atPath: cancelled.outputURL.path))
        } catch {
            task.cancel()
            // Drain the cooperative fixture on readiness/assertion/parent-cancellation errors too.
            if let url = try? await task.value { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    private func item(_ id: String, path: String? = nil) -> HMMediaItem {
        HMMediaItem(id: id, url: FileManager.default.temporaryDirectory.appendingPathComponent("hotmic-review-\(path ?? id).mp4"))
    }
    @Test("No-op operations are silent and animated requests survive only unchanged endpoint positions")
    func mutations() {
        let player = HMPlayer(); player.isFeedVisible = false
        defer { player.teardown() }
        player.replaceAll([item("a"), item("b"), item("c"), item("d")], startAt: 1)
        player.requestPage(at: 2)
        let request = player.pageRequestID, revision = player.playlistRevision
        let change = player.lastPlaylistChange
        player.jump(toID: "missing")
        let error = player.loadError, event = player.lastEvent
        player.replaceAll(player.items, startAt: 1)
        player.reconcile([])
        #expect(player.loadError == error)
        player.reconcile(player.items)
        player.append([]); player.insertNext([]); player.remove(ids: ["unknown"])
        #expect(player.lastPlaylistChange == change)
        #expect(player.playlistRevision == revision); #expect(player.lastEvent == event)
        #expect(player.pageRequestID == request)
        player.append([item("e")]); #expect(player.requestedPageID == "c"); #expect(player.pageRequestID == request)
        player.replaceUpcoming([item("c"), item("x")]); #expect(player.requestedPageID == "c")
        player.insertNext([item("z")]); #expect(player.requestedPageID == nil)
    }
    @Test("Metadata refresh keeps native assignments; ranked edits summarize insertions, removals and moves")
    func rankedNative() throws {
        let player = HMPlayer(configuration: HMPlayerConfiguration(managesAudioSession: false)); player.isFeedVisible = false
        defer { player.teardown() }
        player.replaceAll([item("a"), item("b"), item("c"), item("d")], startAt: 1)
        let current = player.pool.node(for: item("b"), protecting: [])
        let next = player.pool.node(for: item("c"), protecting: ["b"])
        let nativeCurrent = current.player.currentItem, nativeNext = next.player.currentItem
        let refreshed = player.items.map { HMMediaItem(id: $0.id, source: $0.source, title: "Latest", metadata: ["refresh": "1"]) }
        #expect(player.replaceAll(refreshed, startAt: 1))
        #expect(current.player.currentItem === nativeCurrent && next.player.currentItem === nativeNext)
        #expect(current.item?.title == "Latest" && next.item?.metadata == ["refresh": "1"])
        let metadata = try #require(player.lastPlaylistChange)
        #expect(!metadata.currentChanged && metadata.releasedPlayerCount == 0)
        #expect(metadata == HMPlaylistChange(insertedIDs: [], removedIDs: [], movedIDs: [],
            currentChanged: false, releasedItemIDs: []))
        let revision = player.playlistRevision
        #expect(player.replaceAll(refreshed, startAt: 1)); #expect(player.playlistRevision == revision)
        #expect(player.reconcile([item("b"), item("d"), item("x")]))
        let change = try #require(player.lastPlaylistChange)
        #expect(player.items.map(\.id) == ["a", "b", "d", "x"])
        #expect(change.insertedIDs == ["x"] && change.removedIDs == ["c"] && change.movedIDs == ["d"])
        #expect(change.releasedItemIDs == ["c"] && !change.currentChanged)
        #expect(!player.reconcile([item("b"), item("b")]))
        #expect(player.lastPlaylistChange == change)
        #expect(player.replaceAll([item("b", path: "new-media")]))
        #expect(player.lastPlaylistChange?.currentChanged == true)
        #expect(player.lastPlaylistChange?.releasedItemIDs == ["b"])
    }
    @Test("Visible current changes retain warm assignments despite deactivation seeks")
    func visibleReleases() throws {
        var configuration = HMPlayerConfiguration(poolSize: 3, managesAudioSession: false)
        configuration.restoresPlaybackPosition = false
        let player = HMPlayer(configuration: configuration)
        defer { player.teardown() }
        #expect(player.isFeedVisible)
        player.replaceAll([item("a"), item("b"), item("c")])
        let previous = player.pool.node(for: item("a"), protecting: [])
        let next = player.pool.node(for: item("b"), protecting: ["a"])
        previous.activate()
        let native = previous.player.currentItem, generation = previous.assignmentGeneration
        let display = previous.displayRevision
        #expect(player.replaceAll(player.items, startAt: 1))
        #expect(previous.displayRevision > display) // rewind invalidates display continuity
        #expect(previous.assignmentGeneration == generation && previous.player.currentItem === native)
        #expect(player.pool.existingNode(for: item("a")) === previous)
        #expect(player.pool.existingNode(for: item("b")) === next)
        #expect(player.lastPlaylistChange?.currentChanged == true)
        #expect(player.lastPlaylistChange?.releasedItemIDs == [])
    }
    @Test("Finish-once removal advances immediately for ended, failed or failure-idle current", arguments: ["ended", "failed", "idle", "fails-while-finishing"])
    func cannotFinish(mode: String) async throws {
        var configuration = HMPlayerConfiguration(loops: false, managesAudioSession: false, failedItemPolicy: mode == "idle" ? .skip : .stay)
        configuration.removedCurrentPolicy = .finishThenAdvance
        let player = HMPlayer(configuration: configuration); player.isFeedVisible = false
        defer { player.teardown() }
        let a = item("a"), b = item("b")
        player.replaceAll(mode == "idle" ? [a] : [a, b])
        let node = player.pool.node(for: a, protecting: [])
        if mode == "ended" {
            let native = try #require(node.player.currentItem)
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: native)
            let deadline = Date().addingTimeInterval(1)
            while !node.hasReachedEnd, Date() < deadline { await Task.yield() }
            #expect(node.hasReachedEnd)
        } else {
            if mode == "fails-while-finishing" { player.remove(ids: [a.id]); #expect(node.finishesThenLeaves) }
            player.pool.onEvent?(HMPlaybackEvent(kind: .error, itemID: a.id), a)
            if mode == "idle" {
                let deadline = Date().addingTimeInterval(1)
                while player.currentItem != nil, Date() < deadline { await Task.yield() }
                #expect(player.currentItem == nil)
            }
        }
        if mode != "fails-while-finishing" { player.remove(ids: [a.id]) }
        #expect(!player.items.contains(where: { $0.id == a.id }))
        #expect(player.currentItem?.id == (mode == "idle" ? nil : b.id))
        #expect(player.lastPlaylistChange?.currentChanged == (mode != "idle"))
    }
    @Test("History-only reconciliation remains idle when the visible feed settles", arguments: [HMRemovedCurrentPolicy.advanceNow, .finishThenAdvance])
    func idleHistory(policy: HMRemovedCurrentPolicy) async throws {
        var configuration = HMPlayerConfiguration(managesAudioSession: false)
        configuration.removedCurrentPolicy = policy
        let player = HMPlayer(configuration: configuration); player.isFeedVisible = false
        defer { player.teardown() }
        player.replaceAll([item("a"), item("b")], startAt: 1)
        let node = player.pool.node(for: item("b"), protecting: [])
        player.reconcile([item("a")])
        if policy == .finishThenAdvance {
            let native = try #require(node.player.currentItem)
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: native)
            let deadline = Date().addingTimeInterval(1)
            while player.currentItem != nil, Date() < deadline { await Task.yield() }
        }
        #expect(player.currentItem == nil && player.currentIndex == nil && player.activeIndex == 0)
        player.commitPage(toID: "a", requestedAt: ProcessInfo.processInfo.systemUptime)
        #expect(player.currentItem == nil && player.items.map(\.id) == ["a"])
        player.insertNext([item("c")])
        #expect(player.currentItem?.id == "c")
    }
    @Test("Finish-once removal retains current until end; a swipe consumes removal and selects its target", arguments: [false, true])
    func finishingCurrent(swipe: Bool) async throws {
        var configuration = HMPlayerConfiguration(managesAudioSession: false)
        configuration.removedCurrentPolicy = .finishThenAdvance; configuration.loops = true
        let player = HMPlayer(configuration: configuration); player.isFeedVisible = false
        defer { player.teardown() }
        player.replaceAll([item("a"), item("b"), item("c")])
        let node = player.pool.node(for: item("a"), protecting: [])
        let native = try #require(node.player.currentItem)
        #expect(player.reconcile([item("b"), item("c")]))
        #expect(player.currentItem?.id == "a" && node.player.currentItem === native)
        #expect(player.lastPlaylistChange?.removedIDs == [] && node.finishesThenLeaves)
        let revision = player.playlistRevision
        player.replaceAll(player.items, startAt: player.activeIndex)
        #expect(player.playlistRevision == revision && node.finishesThenLeaves)
        if swipe { player.jump(toID: "c") }
        else {
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: native)
            let deadline = Date().addingTimeInterval(1)
            while player.currentItem?.id == "a", Date() < deadline { await Task.yield() }
        }
        #expect(player.currentItem?.id == (swipe ? "c" : "b"))
        #expect(player.items.map(\.id) == ["b", "c"])
        #expect(player.configuration.loops)
        #expect(player.lastPlaylistChange?.removedIDs == ["a"])
        player.remove(ids: Set(player.items.map(\.id)))
        #expect(player.currentItem != nil) // final removed visit is retained, too
        player.configuration.removedCurrentPolicy = .advanceNow
        player.remove(ids: Set(player.items.map(\.id)))
        #expect(player.currentItem == nil)
    }
    @Test("In-flight prefixes survive metadata/order edits and only departed items are cancelled")
    func overlappingPrefetch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HotMic-prefix-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        // A valid range whose tail is withheld: `a` stays on the wire, holding the serial prefix slot.
        let origin = try PrefixOrigin(mode: .gatedRange)
        defer { origin.stop(); #expect(!origin.gateExpired) }
        let deadline = Date().addingTimeInterval(3)
        while (origin.listener.port?.rawValue ?? 0) == 0, Date() < deadline { await Task.yield() }
        let port = try #require(origin.listener.port?.rawValue)
        let a = HMMediaItem(id: "a", url: URL(string: "http://127.0.0.1:\(port)/a.mp4")!)
        let b = HMMediaItem(id: "b", url: URL(string: "http://127.0.0.1:\(port)/b.mp4")!)
        var configuration = HMPlayerConfiguration()
        configuration.volatileSigningQueryParameters = ["token"]
        let transport = try HMCacheTransport(configuration: configuration, directory: directory)
        var work: [String] = []
        await transport.setEventHandler { event, item in
            if let phase = event.properties["prefetch_work"] {
                work.append("\(item.id):\(phase):\(event.properties["work_token"] ?? "")")
            }
            origin.recordProgress("event \(item.id)", event: event)
        }
        do {
        #expect(await transport.start())
        await transport.prioritizePlayback(a, urgent: false)
        let plan = HMPrefetchPlan(itemsAhead: 2, itemsBehind: 0, bytesPerItem: 262144, secondsPerItem: nil,
            keepReadyPlayer: true, startingBitRate: 600000, concurrency: 2, startAfterSeconds: 0, reason: "test")
        await transport.prefetch([a, b], keeping: [a, b], plan: plan)
        let tokens = await transport.activePrefetchTokens
        #expect(tokens.count == 1)
        let tokenA = try #require(tokens["a"])
        #expect(transport.state.isPrefixing(b) && !transport.state.isPrefixRunning(b))
        // A started token is not yet a transfer: until its task reaches the scheduler,
        // a reorder legitimately parks it before any byte and admits the new head.
        // Edits below must preserve a prefix that is actually in flight.
        try await waitForNativeProgress(origin, phase: "a in flight") {
            origin.requestCount(path: "/a.mp4") == 1 && origin.hasHeldResponse
        }
        #expect(await transport.activePrefetchTokens == tokens)
        var presentationOnly = configuration; presentationOnly.presentation = .fit; presentationOnly.removedCurrentPolicy = .finishThenAdvance
        await transport.updateConfiguration(presentationOnly)
        #expect(await transport.activePrefetchTokens == tokens)
        let metadata = HMMediaItem(id: a.id, source: a.source, title: "New")
        await transport.retainWindow([b, metadata])
        await transport.prefetch([b, metadata], keeping: [b, metadata], plan: plan)
        #expect(await transport.activePrefetchTokens == tokens)
        let signed = HMMediaItem(id: a.id, url: URL(string: a.url!.absoluteString + "?token=new")!)
        await transport.retainWindow([signed, b])
        await transport.prefetch([signed, b], keeping: [signed, b], plan: plan)
        #expect(await transport.activePrefetchTokens == tokens)
        #expect(transport.state.isPrefixing(b) && !transport.state.isPrefixRunning(b))
        await transport.retainWindow([signed])
        #expect(await transport.activePrefetchTokens == ["a": tokenA])
        #expect(!transport.state.isPrefixing(b))
        // The original connection then delivers the whole range once, under the signed item's cache key.
        origin.releaseResponses()
        let token = tokenA.uuidString
        try await waitForNativeProgress(origin, phase: "a completes") { work.contains("a:completed:\(token)") }
        #expect(work == ["a:started:\(token)", "a:completed:\(token)"])
        #expect(await transport.activePrefetchTokens.isEmpty)
        #expect(await transport.cachedBytes[HMCacheKey.canonical(signed.url!, ignoring: ["token"])] == 32)
        #expect(origin.requestCount(path: "/a.mp4") == 1 && origin.requestCount(path: "/b.mp4") == 0)
        _ = await transport.finish()
        } catch {
            _ = await transport.finish()
            throw error
        }
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
        var configuration = HMPlayerConfiguration()
        configuration.volatileSigningQueryParameters = ["token"]
        let pool = HMPlayerPool(configuration: configuration)
        let old = HMMediaItem(id: "next", url: URL(string: "https://example.com/next.mp4?variant=1&token=old")!), replacement = item("next", path: "new-media")
        let node = pool.node(for: old, protecting: [])
        let now = ProcessInfo.processInfo.systemUptime
        #expect(node.isWaitingForWarmFrame(at: now))
        #expect(!node.isWaitingForWarmFrame(at: now + 3))
        #expect(pool.existingNode(for: replacement) == nil)
        let nativeItem = node.player.currentItem, revision = node.displayRevision
        let refreshed = HMMediaItem(id: old.id, source: old.source, posterURL: URL(string: "https://example.com/poster.jpg"), title: "New title", metadata: ["rank": "2"])
        pool.trim(keeping: [refreshed]); #expect(pool.existingNode(for: refreshed) === node)
        #expect(node.item == refreshed); #expect(node.player.currentItem === nativeItem)
        #expect(node.displayRevision == revision)
        let signed = HMMediaItem(id: old.id, url: URL(string: "https://example.com/next.mp4?variant=1&token=new")!)
        pool.trim(keeping: [signed]); #expect(pool.existingNode(for: signed) === node)
        #expect(node.player.currentItem === nativeItem && node.item?.url == signed.url)
        let variant = HMMediaItem(id: old.id, url: URL(string: "https://example.com/next.mp4?variant=2&token=new")!)
        #expect(pool.existingNode(for: variant) == nil)
        pool.trim(keeping: [replacement]); #expect(pool.busyCount == 0)
        let replaced = pool.node(for: replacement, protecting: [])
        #expect(replaced.item == replacement)
        #expect((replaced.player.currentItem?.asset as? AVURLAsset)?.url == replacement.url)
        pool.releaseAll()
    }
    @Test("Routes compare media identity; listener re-arms on use and publishes only a healthy port")
    func routesAndRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HotMic-review-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = try HMCacheTransport(configuration: .default, directory: directory)
        do {
        let old = HMMediaItem(id: "same", url: URL(string: "https://example.com/old.mp4")!)
        let new = HMMediaItem(id: "same", url: URL(string: "https://example.com/new.mp4")!)
        #expect(await transport.start())
        transport.state.prune(keeping: [old])
        let route = transport.url(for: old)!
        #expect(route.host == "127.0.0.1")
        let metadata = HMMediaItem(id: old.id, source: old.source, title: "Refreshed")
        transport.state.prune(keeping: [metadata])
        #expect(transport.url(for: metadata) == route)
        let signedState = HMProxyState(signingParameters: ["token"])
        signedState.setPort(12345)
        let signedOld = HMMediaItem(id: "signed", url: URL(string: "https://example.com/clip.mp4?token=old")!)
        let signedNew = HMMediaItem(id: signedOld.id, url: URL(string: "https://example.com/clip.mp4?token=new")!)
        signedState.prune(keeping: [signedOld])
        let signedRoute = signedState.url(signedOld.url!, item: signedOld)
        signedState.prune(keeping: [signedNew])
        #expect(signedState.url(signedNew.url!, item: signedNew) == signedRoute)
        #expect(signedState.allURLs() == [signedNew.url!])
        transport.state.prune(keeping: [new])
        #expect(transport.state.allURLs().isEmpty)
        await transport.interruptListenerForTesting()
        let deadline = Date().addingTimeInterval(3)
        while transport.state.port != 0, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(transport.state.port == 0)
        #expect(transport.url(for: new) == new.url) // safe direct fallback while checking health
        while transport.state.port == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(transport.state.port != 0)
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(transport.state.port)/health")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(transport.url(for: new)?.host == "127.0.0.1")
        // A two-byte native probe establishes total size. The subsequent miss
        // must reach the client before the upstream range completes.
        let origin = try PrefixOrigin()
        defer { origin.stop() }
        // NWListener can publish .any (rawValue 0) before it is ready.
        while (origin.listener.port?.rawValue ?? 0) == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let port = try #require(origin.listener.port)
        try #require(port.rawValue != 0)
        let media = URL(string: "http://127.0.0.1:\(port.rawValue)/slow.mp4")!
        let entry = HMMediaItem(id: "progressive", url: media)
        let cache = HMDiskCache.shared(directory: directory, capacity: 128_000_000)
        await cache.put(key: media.absoluteString, start: 0, data: Data([7, 7]), total: 262144,
                        mime: "video/mp4", base: media, owner: media.absoluteString, prefetched: false, played: true)
        transport.state.prune(keeping: [entry])
        await transport.prioritizePlayback(old, urgent: true)
        let reader = Task {
            var request = URLRequest(url: transport.url(for: entry)!)
            request.setValue("bytes=0-262143", forHTTPHeaderField: "Range")
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 206)
            var prefix = Data()
            for try await byte in bytes { prefix.append(byte); if prefix.count == 16 { break } }
            return prefix
        }
        let timeout = Task { try await Task.sleep(for: .seconds(3)); reader.cancel() }
        defer { timeout.cancel() }
        let heldDeadline = Date().addingTimeInterval(2)
        while await transport.heldPlaybackRequestCount == 0, Date() < heldDeadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await transport.heldPlaybackRequestCount == 1)
        // Promoting a held neighbour releases its original proxy request.
        await transport.prioritizePlayback(entry, urgent: true)
        await transport.markPlayed(entry)
        #expect(try await reader.value == Data(repeating: 7, count: 16))
        let sharedMedia = URL(string: "http://127.0.0.1:\(port.rawValue)/shared-large.mp4")!
        await cache.put(key: sharedMedia.absoluteString, start: 0, data: Data([7, 7]), total: 262144,
            mime: "video/mp4", base: sharedMedia, owner: sharedMedia.absoluteString, prefetched: false, played: false)
        let warmOwner = HMMediaItem(id: "warm-shared", url: sharedMedia), promoted = HMMediaItem(id: "current-shared", url: sharedMedia)
        var receivedWarmPrefix = false, preemptions = 0
        await transport.setEventHandler { event, _ in
            if event.properties["reason"] == "current-shared-resource-preemption" { preemptions += 1 }
        }
        await transport.retainWindow([warmOwner, promoted])
        transport.state.prune(keeping: [warmOwner, promoted])
        await transport.prioritizePlayback(old, urgent: false)
        let nativeOwner = Task {
            var request = URLRequest(url: transport.url(for: warmOwner)!)
            request.setValue("bytes=0-262143", forHTTPHeaderField: "Range")
            let (bytes, _) = try await URLSession.shared.bytes(for: request)
            var received = 0
            for try await _ in bytes {
                received += 1
                if received == 16 { receivedWarmPrefix = true; try await Task.sleep(for: .seconds(60)) }
            }
        }
        let parked = Date().addingTimeInterval(2)
        while !receivedWarmPrefix, Date() < parked { try await Task.sleep(for: .milliseconds(10)) }
        #expect(receivedWarmPrefix)
        await transport.prioritizePlayback(promoted, urgent: true)
        await transport.markPlayed(promoted)
        var sharedRequest = URLRequest(url: transport.url(for: promoted)!)
        sharedRequest.setValue("bytes=0-15", forHTTPHeaderField: "Range"); sharedRequest.timeoutInterval = 2
        let (sharedBytes, _) = try await URLSession.shared.data(for: sharedRequest)
        #expect(sharedBytes == Data(repeating: 7, count: 16))
        #expect(preemptions == 1)
        #expect(origin.requestCount(path: "/shared-large.mp4") == 1) // Current consumes the cancelled owner's received bytes.
        nativeOwner.cancel()
        _ = try? await nativeOwner.value
        for mode in [PrefixOrigin.Mode.shortRange, .ignoresRange] {
            let fixture = try PrefixOrigin(mode: mode)
            defer { fixture.stop(); #expect(!fixture.gateExpired) }
            let readyDeadline = Date().addingTimeInterval(2)
            while (fixture.listener.port?.rawValue ?? 0) == 0, Date() < readyDeadline { try await Task.sleep(for: .milliseconds(10)) }
            let fixturePort = try #require(fixture.listener.port)
            try #require(fixturePort.rawValue != 0)
            let url = URL(string: "http://127.0.0.1:\(fixturePort.rawValue)/bounded.mp4")!
            var headRequest = URLRequest(url: url); headRequest.httpMethod = "HEAD"
            let headResult = try await HMHTTPFetcher(limit: 1).load(headRequest)
            #expect(headResult.data.isEmpty && headResult.response.expectedContentLength == 32)

            let bounded = HMMediaItem(id: "bounded-\(fixturePort)", url: url)
            await cache.put(key: url.absoluteString, start: 31, data: Data([7]), total: 32,
                            mime: "video/mp4", base: url, owner: url.absoluteString, prefetched: false, played: true)
            transport.state.prune(keeping: [bounded])
            await transport.prioritizePlayback(bounded, urgent: true)
            await transport.markPlayed(bounded)
            var request = URLRequest(url: transport.url(for: bounded)!)
            let count = mode == .shortRange ? 32 : 8
            request.setValue("bytes=0-\(count - 1)", forHTTPHeaderField: "Range")
            request.timeoutInterval = 3
            let (data, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.expectedContentLength == Int64(count))
            #expect(data == Data(repeating: 7, count: count))
            if mode == .ignoresRange {
                var directFallbacks = 0
                await transport.setEventHandler { event, item in
                    if item.id == bounded.id, event.properties["native_direct_fallback"] == "origin-range-unsupported" { directFallbacks += 1 }
                }
                // A missing suffix must request native direct fallback rather than
                // repeat truncated 200 responses. The zero-start bounded read above
                // remains reusable and is not treated as a terminal media failure.
                var tail = URLRequest(url: transport.url(for: bounded)!)
                tail.setValue("bytes=8-15", forHTTPHeaderField: "Range"); tail.timeoutInterval = 3
                _ = try? await URLSession.shared.data(for: tail)
                let deliveredDeadline = Date().addingTimeInterval(1)
                while directFallbacks == 0, Date() < deliveredDeadline { try await Task.sleep(for: .milliseconds(10)) }
                #expect(directFallbacks == 1)
            }
        }
        // The origin withholds its tail until contention is observed. This is
        // a real streaming native owner, not a parked task or a timing assumption.
        let healthy = try PrefixOrigin(mode: .gatedRange)
        defer { healthy.stop(); #expect(!healthy.gateExpired) }
        let healthyReady = Date().addingTimeInterval(2)
        while (healthy.listener.port?.rawValue ?? 0) == 0, Date() < healthyReady { try await Task.sleep(for: .milliseconds(10)) }
        let healthyPort = try #require(healthy.listener.port)
        let healthyURL = URL(string: "http://127.0.0.1:\(healthyPort.rawValue)/healthy.mp4")!
        let same = HMMediaItem(id: "healthy-next", url: healthyURL, format: .mp4)
        await transport.updateConfiguration(.default)
        await transport.retainWindow([old, same]); transport.state.prune(keeping: [old, same])
        await transport.prioritizePlayback(old, urgent: true, admitting: same)
        var firstBytes = false, healthyPreemptions = 0, healthyCompleted = false, joins = 0
        await transport.setEventHandler { event, item in
            guard item.id == same.id else { return }
            if event.properties["reason"] == "prefix-shared-resource-preemption" { healthyPreemptions += 1 }
            if event.properties["prefetch_work"] == "completed" { healthyCompleted = true }
            joins += Int(event.metrics["prefetch_join"] ?? 0)
        }
        let healthyReader = Task {
            let (bytes, _) = try await URLSession.shared.bytes(from: transport.url(for: same)!)
            var data = Data()
            for try await byte in bytes { data.append(byte); if data.count == 4 { firstBytes = true } }
            return data
        }
        let streaming = Date().addingTimeInterval(2)
        while !firstBytes, Date() < streaming { try await Task.sleep(for: .milliseconds(10)) }
        try #require(firstBytes)
        let healthyPlan = HMPrefetchPlan(itemsAhead: 1, bytesPerItem: 1024, secondsPerItem: 4, reason: "healthy coalescing acceptance")
        for cancel in [true, false] {
            healthyCompleted = false
            await transport.prefetch([same], keeping: [old, same], plan: healthyPlan)
            let joined = Date().addingTimeInterval(2)
            while await transport.joinedPlaybackRequestCount == 0, Date() < joined { try await Task.sleep(for: .milliseconds(10)) }
            #expect(await transport.joinedPlaybackRequestCount == 1)
            if cancel {
                await transport.cancelPrefetch()
                let drained = Date().addingTimeInterval(2)
                while await transport.joinedPlaybackRequestCount > 0, Date() < drained { try await Task.sleep(for: .milliseconds(10)) }
                #expect(await transport.joinedPlaybackRequestCount == 0)
            }
        }
        healthy.releaseResponses()
        #expect(try await healthyReader.value == Data(repeating: 7, count: 32))
        let coalesced = Date().addingTimeInterval(3)
        while !healthyCompleted, Date() < coalesced { try await Task.sleep(for: .milliseconds(10)) }
        #expect(healthyCompleted && joins >= 2 && healthyPreemptions == 0)
        #expect(healthy.requestCount(path: "/healthy.mp4") == 1)
        print("Transport healthy: joins=\(joins) prefix_preemptions=\(healthyPreemptions) origin_GETs=\(healthy.requestCount(path: "/healthy.mp4")) retained_bytes=32")
        #expect(await cache.available(key: healthyURL.absoluteString, start: 0, count: 32)?.data == Data(repeating: 7, count: 32))
        // A real TCP client advertises a tiny receive window and stops reading.
        // Its sustained send wait must retire safely, retaining the pending chunk
        // without attributing that chunk as successfully delivered to playback.
        print("Transport bulk phase: setup")
        let backpressured = try PrefixOrigin(mode: .bulk)
        defer { backpressured.stop(); #expect(!backpressured.gateExpired) }
        let bulkReady = Date().addingTimeInterval(2)
        while (backpressured.listener.port?.rawValue ?? 0) == 0, Date() < bulkReady { try await Task.sleep(for: .milliseconds(10)) }
        let bulkPort = try #require(backpressured.listener.port)
        let bulkURL = URL(string: "http://127.0.0.1:\(bulkPort.rawValue)/bulk.mp4")!
        let bulkTotal = 8 * 1024 * 1024
        let bulkWarm = HMMediaItem(id: "blocked-client", url: bulkURL, format: .mp4)
        let bulkPrefix = HMMediaItem(id: "blocked-client-prefix", url: bulkURL, format: .mp4)
        await transport.retainWindow([old, bulkWarm, bulkPrefix]); transport.state.prune(keeping: [old, bulkWarm, bulkPrefix])
        await transport.prioritizePlayback(old, urgent: false)
        await cache.put(key: bulkURL.absoluteString, start: bulkTotal - 1, data: Data([7]), total: bulkTotal,
                        mime: "video/mp4", base: bulkURL, owner: bulkURL.absoluteString, prefetched: false, played: false)
        let bulkProxy = try #require(transport.url(for: bulkWarm))
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        try #require(socket >= 0)
        defer { Darwin.close(socket) }
        var receiveBuffer: Int32 = 1024
        #expect(setsockopt(socket, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout.size(ofValue: receiveBuffer))) == 0)
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(bulkProxy.port!).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(connected == 0)
        var blockedPreemptions = 0, bulkComplete = false, nativeReceived = 0
        await transport.setEventHandler { event, item in
            if item.id == bulkWarm.id {
                if event.properties["reason"] == "prefix-shared-resource-preemption" {
                    blockedPreemptions += 1; backpressured.holdBulkResponses()
                }
                nativeReceived += Int(event.metrics["network_bytes"] ?? 0)
            }
            if item.id == bulkPrefix.id, event.properties["prefetch_work"] == "completed" { bulkComplete = true }
        }
        let nativeRequest = Data("GET \(bulkProxy.path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".utf8)
        #expect(nativeRequest.withUnsafeBytes { Darwin.send(socket, $0.baseAddress, $0.count, 0) } == nativeRequest.count)
        print("Transport bulk phase: awaiting-native-park")
        let clientBlocked = Date().addingTimeInterval(4)
        while await transport.parkedNativeRequestCount == 0, Date() < clientBlocked { try await Task.sleep(for: .milliseconds(10)) }
        try #require(await transport.parkedNativeRequestCount > 0)
        print("Transport bulk phase: prefetch-enter native_received=\(nativeReceived)")
        await transport.prefetch([bulkPrefix], keeping: [old, bulkWarm, bulkPrefix], plan: HMPrefetchPlan(itemsAhead: 1, bytesPerItem: bulkTotal, secondsPerItem: 4, reason: "client backpressure acceptance"))
        print("Transport bulk phase: prefetch-return")
        let blocked = Date().addingTimeInterval(4)
        while !backpressured.hasHeldResponse, Date() < blocked { try await Task.sleep(for: .milliseconds(10)) }
        print("Transport bulk phase: held-response preemptions=\(blockedPreemptions) native_received=\(nativeReceived) held=\(backpressured.hasHeldResponse)")
        try #require(blockedPreemptions == 1 && nativeReceived > 0 && backpressured.hasHeldResponse)
        try #require(!backpressured.gateExpired)
        let retained = try await cachedPrefix(cache, url: bulkURL, total: bulkTotal, phase: "before-release")
        // The close event precedes cancellation's final byte accounting. Wait
        // for that receipt explicitly rather than assuming actor delivery order.
        let accounted = Date().addingTimeInterval(2)
        while nativeReceived < retained.count, Date() < accounted { try await Task.sleep(for: .milliseconds(10)) }
        print("Transport bulk phase: retained-prefix bytes=\(retained.count) native_received=\(nativeReceived)")
        #expect(retained.count == nativeReceived)
        let retainedBytesMatch = retained.allSatisfy { $0 == 7 }
        #expect(retainedBytesMatch)
        #expect(backpressured.lastRangeStart(path: "/bulk.mp4") == retained.count)
        try #require(!backpressured.gateExpired)
        print("Transport bulk phase: release-responses")
        backpressured.releaseResponses()
        let bulkFinished = Date().addingTimeInterval(3)
        while !bulkComplete, Date() < bulkFinished { try await Task.sleep(for: .milliseconds(10)) }
        print("Transport bulk phase: completed=\(bulkComplete) preemptions=\(blockedPreemptions)")
        try #require(bulkComplete && blockedPreemptions == 1)
        #expect(!backpressured.gateExpired)
        let allRetained = try await cachedPrefix(cache, url: bulkURL, total: bulkTotal, phase: "after-release")
        #expect(allRetained.count == bulkTotal)
        let allBytesMatch = allRetained.allSatisfy { $0 == 7 }
        #expect(allBytesMatch)
        print("Transport backpressure: prefix_preemptions=\(blockedPreemptions) native_received=\(nativeReceived) retained_before_suffix=\(retained.count) final_retained=\(allRetained.count) origin_GETs=\(backpressured.requestCount(path: "/bulk.mp4"))")
        // A warm native reader parked for budget or activation must not monopolize
        // the serial prefix slot for a distinct entry sharing its exact URL.
        for (mode, knownTotal, cap, sameID) in [(PrefixOrigin.Mode.shortRange, true, 8, false), (.shortRange, true, 8, true), (.oversized200, false, 1024, false), (.oversized200, true, 1024, false), (.gatedOversized200, false, 1024, false), (.gatedOversized200, false, 1024, true)] {
            let fixture = try PrefixOrigin(mode: mode)
            defer { fixture.stop(); #expect(!fixture.gateExpired) }
            let ready = Date().addingTimeInterval(2)
            while (fixture.listener.port?.rawValue ?? 0) == 0, Date() < ready { try await Task.sleep(for: .milliseconds(10)) }
            let fixturePort = try #require(fixture.listener.port)
            let lateParking = mode == .gatedOversized200
            let url = URL(string: "http://127.0.0.1:\(fixturePort.rawValue)/\(lateParking ? "part.ts" : "parked.mp4")")!
            let root = lateParking ? url.deletingLastPathComponent().appendingPathComponent("master.m3u8") : url
            let warm = HMMediaItem(id: "parked-native", url: root, format: lateParking ? .hls : .mp4)
            let alias = sameID ? warm : HMMediaItem(id: "distinct-prefix", url: root, format: lateParking ? .hls : .mp4)
            let farther = HMMediaItem(id: "eligible-farther", url: url.deletingLastPathComponent().appendingPathComponent("farther.mp4"), format: .mp4)
            var config = HMPlayerConfiguration.default; config.prefetch.bytesPerItem = cap
            await transport.updateConfiguration(config)
            if knownTotal {
                let total = mode == .shortRange ? 32 : 2048
                await cache.put(key: url.absoluteString, start: total - 1, data: Data([7]), total: total, mime: "video/mp4", base: url, owner: url.absoluteString, prefetched: false, played: false)
            }
            await transport.retainWindow([old, warm, alias, farther])
            transport.state.prune(keeping: [old, warm, alias, farther])
            await transport.prioritizePlayback(old, urgent: false)
            if lateParking {
                // Real native HLS children follow a cached manifest. Prime it so
                // same-entry discovery does not need an unrelated reservation.
                _ = try await URLSession.shared.data(from: transport.url(for: warm)!)
            }
            // One explicit TCP request, with receipts. URLSession may retry a GET
            // disconnected before headers; those are new native owners, not repeat
            // retirements of the same connection. Keep exactly-one retirement strict.
            var prefixPreemptions = 0, completed: Set<String> = [], acceptedBytes: [String: Int] = [:]
            await transport.setEventHandler { event, item in
                if [warm.id, alias.id, farther.id].contains(item.id) {
                    fixture.recordProgress("event item=\(item.id) work=\(event.properties["prefetch_work"] ?? "-") reason=\(event.properties["reason"] ?? "-")", event: event)
                }
                if event.properties["reason"] == "prefix-shared-resource-preemption" { prefixPreemptions += 1 }
                if event.properties["prefetch_work"] == "completed" { completed.insert(item.id) }
                acceptedBytes[item.id, default: 0] += Int(event.metrics["prefetch_bytes"] ?? 0)
            }
            let native = NativeRequestReceipt(url: transport.state.url(url, item: warm))
            defer { native.connection.cancel() }
            let plan = HMPrefetchPlan(itemsAhead: 2, bytesPerItem: cap, secondsPerItem: 4, reason: "parked owner acceptance")
            if lateParking {
                let started = Date().addingTimeInterval(2)
                while fixture.requestCount(path: "/part.ts") == 0, Date() < started { try await Task.sleep(for: .milliseconds(10)) }
                #expect(fixture.requestCount(path: "/part.ts") == 1)
                await transport.prefetch([alias, farther], keeping: [old, warm, alias, farther], plan: plan)
                let joined = Date().addingTimeInterval(2)
                while await transport.joinedPlaybackRequestCount == 0, Date() < joined { try await Task.sleep(for: .milliseconds(10)) }
                #expect(await transport.joinedPlaybackRequestCount > 0)
                // A cancelled metadata waiter must not leave a preemption trigger.
                await transport.cancelPrefetch()
                let drained = Date().addingTimeInterval(2)
                while await transport.joinedPlaybackRequestCount > 0, Date() < drained { try await Task.sleep(for: .milliseconds(10)) }
                #expect(await transport.joinedPlaybackRequestCount == 0 && prefixPreemptions == 0)
                completed.removeAll()
                await transport.prefetch([alias, farther], keeping: [old, warm, alias, farther], plan: plan)
                let rejoined = Date().addingTimeInterval(2)
                while await transport.joinedPlaybackRequestCount == 0, Date() < rejoined { try await Task.sleep(for: .milliseconds(10)) }
                #expect(await transport.joinedPlaybackRequestCount > 0 && prefixPreemptions == 0)
                fixture.releaseResponses() // Now the native header callback parks.
            } else {
                let parked = Date().addingTimeInterval(2)
                while await transport.parkedNativeRequestCount == 0, Date() < parked { try await Task.sleep(for: .milliseconds(10)) }
                #expect(await transport.parkedNativeRequestCount > 0)
                await transport.prefetch([alias, farther], keeping: [old, warm, alias, farther], plan: plan)
            }
            try await waitForNativeProgress(fixture, phase: "parked \(mode) same_ID=\(sameID)") {
                completed.contains(alias.id) && completed.contains(farther.id)
            }
            print("Transport prefix queue: active_tokens=\(await transport.activePrefetchTokens) joined=\(await transport.joinedPlaybackRequestCount)")
            #expect(prefixPreemptions == 1 && completed.contains(alias.id) && completed.contains(farther.id))
            #expect(fixture.requestCount(path: "/farther.mp4") > 0)
            print("Transport parked: mode=\(mode) known_total=\(knownTotal) same_ID=\(sameID) prefix_preemptions=\(prefixPreemptions) farther_GETs=\(fixture.requestCount(path: "/farther.mp4"))")
            let retired = Date().addingTimeInterval(2)
            while !native.finished, Date() < retired { try await Task.sleep(for: .milliseconds(10)) }
            #expect(native.sentRequests == 1 && native.finished)
            #expect(acceptedBytes[warm.id, default: 0] <= cap && acceptedBytes[alias.id, default: 0] <= cap)
            print("Transport native receipts: \(native.receipts) accepted_bytes=\(acceptedBytes)")
            native.connection.cancel()
        }
        // GET-only origins must produce an explicit complete prefix, not just native fallback.
        for mode in [PrefixOrigin.Mode.head403, .head405, .unknownLength, .oversized200] {
            let fixture = try PrefixOrigin(mode: mode)
            defer { fixture.stop(); #expect(!fixture.gateExpired) }
            let ready = Date().addingTimeInterval(2)
            while (fixture.listener.port?.rawValue ?? 0) == 0, Date() < ready { try await Task.sleep(for: .milliseconds(10)) }
            let fixturePort = try #require(fixture.listener.port)
            let url = URL(string: "http://127.0.0.1:\(fixturePort.rawValue)/master.m3u8")!
            let next = HMMediaItem(id: "get-only-\(fixturePort)", url: url, format: .hls)
            var config = HMPlayerConfiguration.default; config.prefetch.bytesPerItem = 1024
            await transport.updateConfiguration(config)
            await transport.prioritizePlayback(old, urgent: true, admitting: next)
            var met: Bool?, payload = 0.0
            await transport.setEventHandler { event, item in
                guard item.id == next.id else { return }
                fixture.recordProgress("event item=\(item.id) work=\(event.properties["prefetch_work"] ?? "-") outcome=\(event.properties["prefix_outcome"] ?? "-")", event: event)
                payload += event.metrics["prefetch_bytes"] ?? 0
                if let value = event.metrics["prefetch_target_met"] { met = value == 1 }
            }
            await transport.prefetch([next], keeping: [old, next], plan: HMPrefetchPlan(itemsAhead: 1, bytesPerItem: 1024, secondsPerItem: 4, reason: "GET-only acceptance"))
            try await waitForNativeProgress(fixture, phase: "GET-only \(mode)") { met != nil }
            #expect(met == (mode != .oversized200))
            #expect(payload <= 1024)
            if mode != .oversized200 {
                // One cached metadata byte plus the missing suffix, never two full downloads.
                #expect(fixture.requestCount(path: "/part.ts") == 2)
                #expect(payload == Double(PrefixOrigin.manifest.utf8.count + 32))
            } else { #expect(payload == Double(PrefixOrigin.manifest.utf8.count)) }
        }
        print("Transport route phase: finish-enter")
        _ = await transport.finish()
        print("Transport route phase: finish-return")
        #expect(await transport.heldPlaybackRequestCount == 0)
        #expect(await transport.joinedPlaybackRequestCount == 0)
        #expect(await transport.parkedNativeRequestCount == 0)
        } catch {
            _ = await transport.finish()
            throw error
        }
    }

    /// Serial range fills and HEAD/GET metadata discovery have multiple responses.
    /// Bound the whole fixture phase and also fail promptly when it stops progressing.
    /// A local delayed-origin run exceeds the old four-second end-to-end predicate
    /// while still completing each response; this does not diagnose a hosted stall.
    private func waitForNativeProgress(_ fixture: PrefixOrigin, phase: String, until complete: () -> Bool) async throws {
        let started = ProcessInfo.processInfo.systemUptime
        while true {
            if complete() {
                print("Transport wait: phase=\(phase) elapsed=\(ProcessInfo.processInfo.systemUptime - started) completed=true receipts=\(fixture.progressReceipts)")
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            let idle = now - max(started, fixture.lastProgress)
            guard now - started < 8, idle < 4 else {
                print("Transport wait: phase=\(phase) elapsed=\(now - started) idle=\(idle) completed=false receipts=\(fixture.progressReceipts)")
                try #require(false, "Native fixture made no bounded progress: \(phase)")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A cache miss ends a scan; an empty hit or unbounded scan is a failure.
    private func cachedPrefix(_ cache: HMDiskCache, url: URL, total: Int, phase: String) async throws -> Data {
        var data = Data()
        let deadline = Date().addingTimeInterval(2)
        while data.count < total {
            try #require(Date() < deadline, "Cache scan deadline: \(phase), cursor=\(data.count)")
            print("Transport bulk cache: phase=\(phase) cursor=\(data.count) read-enter")
            guard let hit = await cache.available(key: url.absoluteString, start: data.count, count: total - data.count) else { break }
            print("Transport bulk cache: phase=\(phase) cursor=\(data.count) bytes=\(hit.data.count)")
            try #require(!hit.data.isEmpty && hit.data.count <= total - data.count, "Cache scan made no valid progress: \(phase)")
            data.append(hit.data)
        }
        return data
    }

    /// No automatic retry, one send and explicit per-connection receive/EOF receipts.
    final class NativeRequestReceipt: @unchecked Sendable {
        let connection: NWConnection
        private let lock = NSLock()
        private var events: [String] = []
        private var sends = 0
        private var ended = false
        var sentRequests: Int { lock.lock(); defer { lock.unlock() }; return sends }
        var finished: Bool { lock.lock(); defer { lock.unlock() }; return ended }
        var receipts: [String] { lock.lock(); defer { lock.unlock() }; return events }
        private func record(_ event: String, sent: Bool = false, end: Bool = false) {
            lock.lock(); events.append(event); if sent { sends += 1 }; if end { ended = true }; lock.unlock()
        }
        init(url: URL) {
            connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(url.port!))!, using: .tcp)
            let request = Data("GET \(url.path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".utf8)
            let attempt = UUID().uuidString
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.record("\(attempt):send", sent: true)
                    self.connection.send(content: request, completion: .contentProcessed { [weak self] error in
                        if let error { self?.record("\(attempt):send-error \(error)", end: true) }
                    })
                    self.receive(attempt)
                case .failed(let error): self.record("\(attempt):failed \(error)", end: true)
                default: break
                }
            }
            connection.start(queue: .global())
        }
        private func receive(_ attempt: String) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] bytes, _, complete, error in
                guard let self else { return }
                self.record("\(attempt):received=\(bytes?.count ?? 0) eof=\(complete) error=\(String(describing: error))", end: complete || error != nil)
                if !complete && error == nil { self.receive(attempt) }
            }
        }
    }

    /// Deliberately never completes its range. A full-buffer proxy cannot pass.
    final class PrefixOrigin: @unchecked Sendable {
        enum Mode: Sendable { case hanging, shortRange, ignoresRange, head403, head405, unknownLength, oversized200, gatedRange, gatedOversized200, bulk }
        static let manifest = "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\npart.ts\n#EXT-X-ENDLIST\n"
        let listener: NWListener
        private let requestLock = NSLock()
        private var progressedAt = 0.0
        private var progress: [String] = []
        var lastProgress: Double { requestLock.lock(); defer { requestLock.unlock() }; return progressedAt }
        var progressReceipts: [String] { requestLock.lock(); defer { requestLock.unlock() }; return progress }
        func recordProgress(_ receipt: String, event: HMPlaybackEvent? = nil) {
            if let event {
                guard event.properties["prefetch_work"] != nil || event.properties["reason"] != nil ||
                      event.metrics["network_bytes", default: 0] > 0 || event.metrics["ttfb_s"] != nil ||
                      event.metrics["prefetch_target_met"] != nil else { return }
            }
            let now = ProcessInfo.processInfo.systemUptime
            requestLock.lock(); progressedAt = max(progressedAt, now)
            // Bounded fixture milestones and request lines, never response payloads.
            if progress.count == 32 { progress.removeFirst() }
            progress.append("\(now):\(receipt)"); requestLock.unlock()
        }
        private var requests: [String: Int] = [:]
        private var rangeStarts: [String: Int] = [:]
        func lastRangeStart(path: String) -> Int? { requestLock.lock(); defer { requestLock.unlock() }; return rangeStarts[path] }
        private var heldResponses: [@Sendable () -> Void] = []
        private var released = false
        private var holdBulk = false
        private var connections: [String: NWConnection] = [:]
        private var stopped = false
        private var gateTimer: DispatchWorkItem?
        private var expired = false
        var gateExpired: Bool { requestLock.lock(); defer { requestLock.unlock() }; return expired }
        func stop() {
            requestLock.lock(); stopped = true; released = true
            gateTimer?.cancel(); gateTimer = nil
            heldResponses.removeAll()
            let owned = Array(connections.values); connections.removeAll(); requestLock.unlock()
            listener.cancel()
            for connection in owned { connection.cancel() }
        }
        private func own(_ connection: NWConnection, attempt: String) -> Bool {
            requestLock.lock(); defer { requestLock.unlock() }
            guard !stopped else { return false }
            connections[attempt] = connection; return true
        }
        private func closed(_ attempt: String) {
            requestLock.lock(); connections[attempt] = nil; requestLock.unlock()
        }
        private func expireGate() {
            requestLock.lock()
            guard !released, !stopped, !heldResponses.isEmpty else { requestLock.unlock(); return }
            expired = true; requestLock.unlock()
            print("Origin response gate: deadline expired; releasing owned responses")
            releaseResponses()
        }
        var hasHeldResponse: Bool { requestLock.lock(); defer { requestLock.unlock() }; return !heldResponses.isEmpty }
        func holdBulkResponses() { requestLock.lock(); holdBulk = true; requestLock.unlock() }
        private var shouldHoldBulk: Bool { requestLock.lock(); defer { requestLock.unlock() }; return holdBulk }
        func releaseResponses() {
            requestLock.lock(); released = true; gateTimer?.cancel(); gateTimer = nil; let responses = heldResponses; heldResponses.removeAll(); requestLock.unlock()
            for response in responses { response() }
        }
        private func hold(_ response: @escaping @Sendable () -> Void) {
            requestLock.lock()
            if released { requestLock.unlock(); response() }
            else {
                heldResponses.append(response)
                if gateTimer == nil {
                    let timer = DispatchWorkItem { [weak self] in self?.expireGate() }
                    gateTimer = timer
                    DispatchQueue.global().asyncAfter(deadline: .now() + 6, execute: timer)
                }
                requestLock.unlock()
            }
        }
        func requestCount(path: String) -> Int { requestLock.lock(); defer { requestLock.unlock() }; return requests[path, default: 0] }
        private func record(_ request: String) {
            guard request.hasPrefix("GET "), let path = request.split(separator: " ").dropFirst().first else { return }
            let range = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range:") }
            let start = range?.dropFirst(6).trimmingCharacters(in: .whitespaces).dropFirst(6).split(separator: "-").first.flatMap { Int($0) } ?? 0
            requestLock.lock(); requests[String(path), default: 0] += 1; rangeStarts[String(path)] = start; requestLock.unlock()
        }
        init(mode: Mode = .hanging) throws {
            listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { [weak self] connection in
                let attempt = UUID().uuidString
                guard self?.own(connection, attempt: attempt) == true else { connection.cancel(); return }
                print("Origin receipt: mode=\(mode) attempt=\(attempt) accepted")
                connection.stateUpdateHandler = { [weak self] state in
                    switch state { case .cancelled, .failed: self?.closed(attempt); default: break }
                    if case .cancelled = state { print("Origin receipt: mode=\(mode) attempt=\(attempt) closed") }
                    if case .failed(let error) = state { print("Origin receipt: mode=\(mode) attempt=\(attempt) failed=\(error)") }
                }
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] request, _, _, _ in
                    let received = String(decoding: request ?? Data(), as: UTF8.self)
                    print("Origin receipt: mode=\(mode) attempt=\(attempt) request=\(received.replacingOccurrences(of: "\r\n", with: " | "))")
                    self?.record(received)
                    self?.recordProgress("request \(received.components(separatedBy: "\r\n").first ?? "")")
                    if mode != .hanging {
                        let text = String(decoding: request ?? Data(), as: UTF8.self)
                        if [.head403, .head405, .unknownLength, .oversized200, .gatedOversized200].contains(mode) {
                            let path = String(text.split(separator: " ").dropFirst().first ?? "")
                            let body = path.hasSuffix(".m3u8") ? Data(Self.manifest.utf8) : Data(repeating: 7, count: [.oversized200, .gatedOversized200].contains(mode) && !path.contains("farther") ? 2048 : 32)
                            let isHead = text.hasPrefix("HEAD ")
                            if isHead {
                                let status = mode == .head403 ? 403 : mode == .unknownLength ? 200 : 405
                                let head = "HTTP/1.1 \(status) Metadata\r\nConnection: close\r\n\r\n"
                                connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in connection.cancel() }); return
                            }
                            let header = text.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range:") }
                            let range = HMByteRange.parse(header.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }, total: body.count)!
                            let ignored = [.oversized200, .gatedOversized200].contains(mode) && !path.hasSuffix(".m3u8") && !path.contains("farther")
                            let data = ignored ? body : body.subdata(in: range.start..<(range.end + 1))
                            let contentRange = ignored ? "" : "Content-Range: bytes \(range.start)-\(range.end)/\(body.count)\r\n"
                            let length = mode == .unknownLength ? "Transfer-Encoding: chunked\r\n" : "Content-Length: \(data.count)\r\n"
                            let head = "HTTP/1.1 \(ignored ? 200 : 206) OK\r\n\(length)\(contentRange)Connection: close\r\n\r\n"
                            var packet = Data(head.utf8)
                            if mode == .unknownLength {
                                packet.append(Data("\(String(data.count, radix: 16))\r\n".utf8)); packet.append(data); packet.append(Data("\r\n0\r\n\r\n".utf8))
                            } else { packet.append(data) }
                            let response = packet
                            let send: @Sendable () -> Void = { connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() }) }
                            if mode == .gatedOversized200 && path.hasSuffix("part.ts") { self?.hold(send) } else { send() }
                            return
                        }
                        if mode == .bulk {
                            let header = text.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range:") }
                            let range = HMByteRange.parse(header.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }, total: 8388608)!
                            let head = "HTTP/1.1 206 OK\r\nContent-Type: video/mp4\r\nContent-Range: bytes \(range.start)-\(range.end)/8388608\r\nContent-Length: \(range.count)\r\nConnection: close\r\n\r\n"
                            var packet = Data(head.utf8); packet.append(Data(repeating: 7, count: range.count))
                            let response = packet
                            let send: @Sendable () -> Void = { connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() }) }
                            if self?.shouldHoldBulk == true { self?.hold(send) } else { send() }
                            return
                        }
                        if text.hasPrefix("HEAD ") {
                            let head = "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: 32\r\nConnection: close\r\n\r\n"
                            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in connection.cancel() }); return
                        }
                        let header = text.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range:") }
                        let range = HMByteRange.parse(header.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }, total: 32)!
                        let count = mode == .shortRange ? min(4, range.count) : mode == .gatedRange ? range.count : 32
                        let status = mode == .ignoresRange ? "200 OK" : "206 Partial Content"
                        let contentRange = mode != .ignoresRange ? "Content-Range: bytes \(range.start)-\(range.start + count - 1)/32\r\n" : ""
                        let head = "HTTP/1.1 \(status)\r\nContent-Type: video/mp4\r\n\(contentRange)Content-Length: \(count)\r\nConnection: close\r\n\r\n"
                        if mode == .gatedRange {
                            var prefix = Data(head.utf8); prefix.append(Data(repeating: 7, count: 4))
                            connection.send(content: prefix, completion: .contentProcessed { [weak self] _ in
                                self?.hold { connection.send(content: Data(repeating: 7, count: count - 4), completion: .contentProcessed { _ in connection.cancel() }) }
                            })
                            return
                        }
                        var packet = Data(head.utf8); packet.append(Data(repeating: 7, count: count))
                        connection.send(content: packet, completion: .contentProcessed { _ in connection.cancel() })
                        return
                    }
                    let head = "HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nContent-Range: bytes 2-262143/262144\r\nContent-Length: 262142\r\nConnection: close\r\n\r\n"
                    var body = Data(head.utf8); body.append(Data(repeating: 7, count: 1024))
                    connection.send(content: body, completion: .contentProcessed { _ in })
                    // Retain until the client cancels, without delivering a tail.
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in connection.cancel() }
                }
            }
            listener.start(queue: .global())
        }
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
        if rejected { player.remove(ids: [player.currentItem!.id]) } else { player.next() }
        while await source.calls < 5, Date() < deadline { await Task.yield() }
        #expect(await source.calls == 5)
        while player.isLoadingPage, Date() < deadline { await Task.yield() }
        await player.loadNextPage()
        #expect(await source.calls == 6)
        try await Task.sleep(for: .milliseconds(25)); #expect(errors == 6)
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
        let revision = player.playlistRevision
        player.replaceAll(player.items, startAt: player.activeIndex)
        #expect(player.playlistRevision == revision && player.isLoadingPage)
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
