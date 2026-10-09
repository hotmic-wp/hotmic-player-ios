import Foundation

/// One page of feed content.
public struct HMPlaylistPage: Sendable {
    /// Entries supplied by this page or static source.
    public let items: [HMMediaItem]
    /// Opaque cursor for the next page. `nil` means the feed has ended.
    public let nextCursor: String?

    /// Creates a page or static paginated source with the supplied entries.
    public init(items: [HMMediaItem], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// Where a feed gets its content.
///
/// Keeping this a protocol is what lets the sample app swap a bundled sample
/// reel for a real paginated API without touching the player.
public protocol HMPlaylistSource: Sendable {
    /// Loads entries after the cursor; a nil next cursor marks the end.
    func loadPage(cursor: String?) async throws -> HMPlaylistPage
}

/// Serves a fixed list, optionally looping forever to fake infinite scroll.
///
/// MOCK — replace with an API-backed source. This is what the sample app uses
/// so the demo has no network dependency beyond the video CDN itself.
public struct HMStaticPlaylistSource: HMPlaylistSource {
    /// Entries supplied by this page or static source.
    public let items: [HMMediaItem]
    /// Maximum number of entries returned per page.
    public let pageSize: Int
    /// When true the source recycles its items with fresh ids, forever.
    public let loopsForever: Bool
    /// Artificial latency so the loading state is actually visible in a demo.
    public let simulatedLatency: Duration

    /// Creates a page or static paginated source with the supplied entries.
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
