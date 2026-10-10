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
            try list.reconcile([clip("b"), clip("x")], policy: policy)
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
        c.followsDeviceRotation = true
        let data = try JSONEncoder().encode(c.benchmarkRecord)
        let restored = try JSONDecoder().decode(HMPlayerConfiguration.BenchmarkRecord.self, from: data).configuration
        #expect(restored.fingerprint == c.fingerprint)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(legacy["failedItemPolicy"] as? String == "stay")
        legacy.removeValue(forKey: "failedItemPolicy"); legacy.removeValue(forKey: "removedCurrentPolicy")
        for key in ["presentation", "aspectRatioTolerance", "backdropColor", "followsDeviceRotation"] { legacy.removeValue(forKey: key) }
        let oldData = try JSONSerialization.data(withJSONObject: legacy)
        #expect(try JSONDecoder().decode(HMPlayerConfiguration.BenchmarkRecord.self, from: oldData).configuration.removedCurrentPolicy == .advanceNow)
        let old = try JSONDecoder().decode(HMPlayerConfiguration.BenchmarkRecord.self, from: oldData).configuration
        #expect(old.failedItemPolicy == .skip && old.presentation == .automatic)
        #expect(old.aspectRatioTolerance == 0.25 && !old.followsDeviceRotation)
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
#if canImport(UIKit)
import UIKit
import SwiftUI
#endif

@Suite("Native review regressions") @MainActor
struct PlayerNativeReviewTests {
    @Test("Warm track detection respects camera transforms before activation", arguments: [false, true])
    func warmDisplayAspect(rotated: Bool) async throws {
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
        #expect(gesture.accessibilityLabel == "Video" && gesture.accessibilityValue != nil)
        #expect(gesture.accessibilityCustomActions?.map(\.name).contains("Fire") == true)
        let cachedActions = gesture.accessibilityCustomActions ?? []
        controller.videoLayout.squeezeTarget?.origin.y += 1
        try await settle()
        #expect(zip(cachedActions, gesture.accessibilityCustomActions ?? []).allSatisfy { $0 === $1 })
        #expect(reportedFrames.last == controller.videoFrame && reportedFrames.count >= 6)
        #expect(gesture.accessibilityActivate() && taps == 1 && fires.isEmpty)
        let action = try #require(gesture.accessibilityCustomActions?.first { $0.name == "Fire" })
        #expect(action.actionHandler?(action) == true)
        #expect(fires == [CGPoint(x: gesture.videoFrame.midX, y: gesture.videoFrame.midY)])
        controller.excludedHitAreas = [CGRect(x: 0, y: 60, width: 100, height: 100)]
        try await settle()
        #expect(!gesture.point(inside: CGPoint(x: 50, y: 100), with: nil))
        #expect(!gesture.acceptsTap(at: CGPoint(x: 50, y: 100), isDoubleTap: true))
        player.pause(); try await settle()
        let playAction = try #require(gesture.accessibilityCustomActions?.first { $0.name == "Play" })
        #expect(playAction.actionHandler?(playAction) == true)
        #expect(taps == 1) // Play/Pause remains reachable even with a host tap override.
        controller.isAdPlaying = true
        try await settle()
        #expect(!gesture.isAccessibilityElement && gesture.accessibilityCustomActions?.isEmpty == true)
        #expect(!gesture.singleTap.isEnabled && !gesture.doubleTap.isEnabled && !gesture.accessibilityActivate())
        controller.isAdPlaying = false; controller.videoLayout.squeezeTarget = nil
        try await settle()
        #expect(gesture.singleTap.isEnabled && gesture.doubleTap.isEnabled)
        #expect(node.player.currentItem === native && node.assignmentGeneration == generation)
    }
    #endif

    /// Small local encoded fixture; tests never depend on a network origin or checked-in video.
    func videoFixture(rotated: Bool) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hotmic-aspect-\(UUID()).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90])
        if rotated { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90])
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, 160, 90, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(try #require(CVPixelBufferGetBaseAddress(pixels)), 64, CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let deadline = Date().addingTimeInterval(2)
        while !input.isReadyForMoreMediaData, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(adaptor.append(pixels, withPresentationTime: .zero))
        writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)
        return url
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
        let origin = try PrefixOrigin(); defer { origin.listener.cancel() }
        let deadline = Date().addingTimeInterval(3)
        while (origin.listener.port?.rawValue ?? 0) == 0, Date() < deadline { await Task.yield() }
        let port = try #require(origin.listener.port?.rawValue)
        let a = HMMediaItem(id: "a", url: URL(string: "http://127.0.0.1:\(port)/a.mp4")!)
        let b = HMMediaItem(id: "b", url: URL(string: "http://127.0.0.1:\(port)/b.mp4")!)
        var configuration = HMPlayerConfiguration()
        configuration.volatileSigningQueryParameters = ["token"]
        let transport = try HMCacheTransport(configuration: configuration, directory: directory)
        #expect(await transport.start())
        await transport.prioritizePlayback(a, urgent: false)
        let plan = HMPrefetchPlan(itemsAhead: 2, itemsBehind: 0, bytesPerItem: 262144, secondsPerItem: nil,
            keepReadyPlayer: true, startingBitRate: 600000, concurrency: 2, startAfterSeconds: 0, reason: "test")
        await transport.prefetch([a, b], keeping: [a, b], plan: plan)
        let tokens = await transport.activePrefetchTokens
        #expect(tokens.count == 2)
        let metadata = HMMediaItem(id: a.id, source: a.source, title: "New")
        await transport.retainWindow([b, metadata])
        await transport.prefetch([b, metadata], keeping: [b, metadata], plan: plan)
        #expect(await transport.activePrefetchTokens == tokens)
        let signed = HMMediaItem(id: a.id, url: URL(string: a.url!.absoluteString + "?token=new")!)
        await transport.retainWindow([signed, b])
        await transport.prefetch([signed, b], keeping: [signed, b], plan: plan)
        #expect(await transport.activePrefetchTokens == tokens)
        await transport.retainWindow([signed])
        #expect(await transport.activePrefetchTokens == ["a": tokens["a"]!])
        _ = await transport.finish()
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
        while transport.state.port != 0, Date() < deadline { await Task.yield() }
        #expect(transport.state.port == 0)
        #expect(transport.url(for: new) == new.url) // safe direct fallback while checking health
        while transport.state.port == 0, Date() < deadline { await Task.yield() }
        #expect(transport.state.port != 0)
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(transport.state.port)/health")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(transport.url(for: new)?.host == "127.0.0.1")
        // A two-byte native probe establishes total size. The subsequent miss
        // must reach the client before the upstream range completes.
        let origin = try PrefixOrigin()
        defer { origin.listener.cancel() }
        // NWListener can publish .any (rawValue 0) before it is ready.
        while (origin.listener.port?.rawValue ?? 0) == 0, Date() < deadline { await Task.yield() }
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
        while await transport.heldPlaybackRequestCount == 0, Date() < heldDeadline { await Task.yield() }
        #expect(await transport.heldPlaybackRequestCount == 1)
        // Promoting a held neighbour releases its original proxy request.
        await transport.prioritizePlayback(entry, urgent: true)
        #expect(try await reader.value == Data(repeating: 7, count: 16))
        for mode in [PrefixOrigin.Mode.shortRange, .ignoresRange] {
            let fixture = try PrefixOrigin(mode: mode)
            defer { fixture.listener.cancel() }
            let readyDeadline = Date().addingTimeInterval(2)
            while (fixture.listener.port?.rawValue ?? 0) == 0, Date() < readyDeadline { await Task.yield() }
            let fixturePort = try #require(fixture.listener.port)
            try #require(fixturePort.rawValue != 0)
            let url = URL(string: "http://127.0.0.1:\(fixturePort.rawValue)/bounded.mp4")!
            let bounded = HMMediaItem(id: "bounded-\(fixturePort)", url: url)
            await cache.put(key: url.absoluteString, start: 31, data: Data([7]), total: 32,
                            mime: "video/mp4", base: url, owner: url.absoluteString, prefetched: false, played: true)
            transport.state.prune(keeping: [bounded])
            await transport.prioritizePlayback(bounded, urgent: true)
            var request = URLRequest(url: transport.url(for: bounded)!)
            let count = mode == .shortRange ? 32 : 8
            request.setValue("bytes=0-\(count - 1)", forHTTPHeaderField: "Range")
            request.timeoutInterval = 3
            let (data, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.expectedContentLength == Int64(count))
            #expect(data == Data(repeating: 7, count: count))
        }
        _ = await transport.finish()
    }

    /// Deliberately never completes its range. A full-buffer proxy cannot pass.
    final class PrefixOrigin: @unchecked Sendable {
        enum Mode: Sendable { case hanging, shortRange, ignoresRange }
        let listener: NWListener
        init(mode: Mode = .hanging) throws {
            listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { connection in
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { request, _, _, _ in
                    if mode != .hanging {
                        let text = String(decoding: request ?? Data(), as: UTF8.self)
                        let header = text.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range:") }
                        let range = HMByteRange.parse(header.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }, total: 32)!
                        let count = mode == .shortRange ? min(4, range.count) : 32
                        let status = mode == .shortRange ? "206 Partial Content" : "200 OK"
                        let contentRange = mode == .shortRange ? "Content-Range: bytes \(range.start)-\(range.start + count - 1)/32\r\n" : ""
                        let head = "HTTP/1.1 \(status)\r\nContent-Type: video/mp4\r\n\(contentRange)Content-Length: \(count)\r\nConnection: close\r\n\r\n"
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
