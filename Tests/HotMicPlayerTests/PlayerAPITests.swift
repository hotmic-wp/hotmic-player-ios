import Foundation
import Testing
@testable import HotMicPlayer

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
