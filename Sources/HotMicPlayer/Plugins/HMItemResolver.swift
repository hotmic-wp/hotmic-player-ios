import Foundation

/// Playable VOD metadata returned by a partner resolver.
public struct HMResolvedItem: Sendable, Equatable {
    /// File or HTTP(S) media URL.
    public let url: URL
    /// Container type, or automatic detection.
    public let format: HMMediaItem.Format
    /// Optional poster fallback.
    public let poster: URL?
    /// Optional title fallback.
    public let title: String?
    /// Optional duration in seconds.
    public let duration: TimeInterval?
    /// Creates a playable result. Explicit playlist metadata takes precedence over these hints.
    public init(url: URL, format: HMMediaItem.Format = .auto, poster: URL? = nil, title: String? = nil, duration: TimeInterval? = nil) {
        self.url = url; self.format = format; self.poster = poster; self.title = title; self.duration = duration
    }
}

/// Resolves opaque references during prefetch. Implementations must cooperate with task cancellation.
public protocol HMItemResolver: Sendable {
    /// Obtains VOD media. Concurrent calls for the same entry are coalesced by the player.
    func resolve(_ ref: HMMediaItem.Reference) async throws -> HMResolvedItem
}

/// Main-actor session cache. Completed results survive window changes; in-flight work does not.
@MainActor final class HMResolutionStore {
    struct Work { let token: UUID; let task: Task<HMResolvedItem, Error> }
    private var completed: [HMMediaItem: HMResolvedItem] = [:]
    private var pending: [HMMediaItem: Work] = [:]
    func cached(_ item: HMMediaItem) -> HMMediaItem? {
        if let url = item.url, item.format != .auto || url.isFileURL { return item }
        return completed[item].map { item.resolved($0) }
    }
    func resolve(_ item: HMMediaItem, using resolver: HMItemResolver?) async throws -> HMMediaItem {
        if let cached = cached(item) { return cached }

        let work: Work
        if let existing = pending[item] { work = existing }
        else {
            work = Work(token: UUID(), task: Task {
                switch item.source {
                case .reference(let namespace, let id):
                    guard let resolver else { throw HMPlayerError.missingResolver }
                    return try await resolver.resolve(.init(namespace: namespace, id: id))
                case .url(let url, _):
                    var request = URLRequest(url: url); request.httpMethod = "HEAD"; request.timeoutInterval = 20
                    let (_, response) = try await URLSession.shared.data(for: request)
                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw HMPlayerError.resolution("Format detection failed for \(item.id)") }
                    let mime = response.mimeType?.lowercased() ?? ""
                    let hls = mime.contains("mpegurl") || response.url?.pathExtension.lowercased() == "m3u8"
                    return HMResolvedItem(url: url, format: hls ? .hls : .mp4)
                }
            })
            pending[item] = work
        }
        do {
            let value = try await work.task.value
            try Task.checkCancellation()
            guard pending[item]?.token == work.token else { throw CancellationError() }
            completed[item] = value; pending[item] = nil
            return item.resolved(value)
        } catch {
            // Another waiter may already have committed this result.
            if let value = completed[item], !Task.isCancelled { return item.resolved(value) }
            if pending[item]?.token == work.token { pending[item] = nil }
            throw error
        }
    }
    func retain(_ window: Set<HMMediaItem>) {
        for (item, work) in pending where !window.contains(item) { work.task.cancel(); pending[item] = nil }
    }
    func cancelAll() { retain([]) }
}
