import Foundation

/// One page of feed content.
public struct HMFeedPage: Sendable {
    public let items: [HMMediaItem]
    /// Opaque cursor for the next page. `nil` means the feed has ended.
    public let nextCursor: String?

    public init(items: [HMMediaItem], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// Where a feed gets its content.
///
/// Keeping this a protocol is what lets the sample app swap a bundled sample
/// reel for a real paginated API without touching the player.
public protocol HMFeedDataSource: Sendable {
    func loadPage(cursor: String?) async throws -> HMFeedPage
}

/// Serves a fixed list, optionally looping forever to fake infinite scroll.
///
/// MOCK — replace with an API-backed source. This is what the sample app uses
/// so the demo has no network dependency beyond the video CDN itself.
public struct HMStaticFeedDataSource: HMFeedDataSource {
    public let items: [HMMediaItem]
    public let pageSize: Int
    /// When true the source recycles its items with fresh ids, forever.
    public let loopsForever: Bool
    /// Artificial latency so the loading state is actually visible in a demo.
    public let simulatedLatency: Duration

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

    public func loadPage(cursor: String?) async throws -> HMFeedPage {
        try await Task.sleep(for: simulatedLatency)
        guard !items.isEmpty else { return HMFeedPage(items: [], nextCursor: nil) }

        let page = Int(cursor ?? "0") ?? 0
        let start = page * pageSize

        if start >= items.count && !loopsForever {
            return HMFeedPage(items: [], nextCursor: nil)
        }

        let slice: [HMMediaItem] = (0..<pageSize).compactMap { offset in
            let index = start + offset
            guard loopsForever || index < items.count else { return nil }
            let source = items[index % items.count]
            guard page > 0 else { return source }
            // Re-issue with a unique id so SwiftUI identity and analytics views
            // stay distinct across laps.
            return HMMediaItem(
                id: "\(source.id)-p\(page)",
                url: source.url,
                posterURL: source.posterURL,
                title: source.title,
                author: source.author,
                durationHint: source.durationHint,
                streamKind: source.streamKind,
                metadata: source.metadata
            )
        }

        return HMFeedPage(items: slice, nextCursor: slice.isEmpty ? nil : String(page + 1))
    }
}
