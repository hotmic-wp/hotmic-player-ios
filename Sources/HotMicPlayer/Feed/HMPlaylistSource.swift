import Foundation

/// One page of feed content.
///
/// Use from any task; mutate only an exclusively owned value.
public struct HMPlaylistPage: Sendable {
    /// Entries supplied by this page or static source.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let items: [HMMediaItem]
    /// Opaque cursor for the next page. `nil` means the feed has ended.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let nextCursor: String?

    /// Creates a page with entries and the next cursor.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public init(items: [HMMediaItem], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// Where a feed gets its content.
///
/// Keeping this a protocol is what lets the sample app swap a bundled sample
/// reel for a real paginated API without touching the player.
///
/// May be called from any task; synchronize implementation state.
public protocol HMPlaylistSource: Sendable {
    /// Loads entries after the cursor; a nil next cursor marks the end.
    ///
    /// May be called from any task; synchronize implementation state.
    func loadPage(cursor: String?) async throws -> HMPlaylistPage
}

/// Serves a fixed list, optionally looping forever to fake infinite scroll.
///
/// Use for local catalogs, prototypes and deterministic paging. Set `loopsForever`
/// to false for a finite catalog and `simulatedLatency` to zero for immediate pages.
///
/// Use from any task; mutate only an exclusively owned value.
public struct HMStaticPlaylistSource: HMPlaylistSource {
    /// Entries supplied by this page or static source.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let items: [HMMediaItem]
    /// Maximum number of entries returned per page.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let pageSize: Int
    /// When true the source recycles its items with fresh ids, forever.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let loopsForever: Bool
    /// Artificial latency so the loading state is actually visible in a demo.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let simulatedLatency: Duration

    /// Creates a fixed catalog with optional looping and simulated page latency.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public init(
        items: [HMMediaItem],
        pageSize: Int = 6,
        loopsForever: Bool = true,
        simulatedLatency: Duration = .milliseconds(350)
    ) {
        self.items = items
        self.pageSize = max(1, pageSize)
        self.loopsForever = loopsForever
        self.simulatedLatency = simulatedLatency
    }

    /// Returns the next page for an opaque cursor; nil starts at the beginning.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public func loadPage(cursor: String?) async throws -> HMPlaylistPage {
        try await Task.sleep(for: simulatedLatency)
        guard !items.isEmpty else { return HMPlaylistPage(items: [], nextCursor: nil) }

        guard let page = Int(cursor ?? "0"), page >= 0, page < Int.max / pageSize else { throw HMPlayerError.playlistSource("Invalid static playlist cursor") }
        let start = page * pageSize

        if start >= items.count && !loopsForever {
            return HMPlaylistPage(items: [], nextCursor: nil)
        }

        let slice: [HMMediaItem] = (0..<pageSize).compactMap { offset in
            let index = start + offset
            guard loopsForever || index < items.count else { return nil }
            let source = items[index % items.count]
            guard index < items.count else { return source.identified("\(source.id)-p\(page)-i\(offset)") }
            return source
        }

        return HMPlaylistPage(items: slice, nextCursor: slice.isEmpty || (!loopsForever && start + slice.count >= items.count) ? nil : String(page + 1))
    }
}
