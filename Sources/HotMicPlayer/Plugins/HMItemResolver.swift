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
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }
    private var completed: [HMMediaItem: HMResolvedItem] = [:]
    private var promotions: [HMMediaItem: Task<Void, Never>] = [:]
    private var pending: [HMMediaItem: Work] = [:]
    func cached(_ item: HMMediaItem, requireFormat: Bool = true) -> HMMediaItem? {
        if let url = item.url, !requireFormat || item.format != .auto || url.isFileURL { return item }
        guard let value = completed[item].map({ item.resolved($0) }) else { return nil }
        return !requireFormat || value.format != .auto ? value : nil
    }
    func resolve(_ item: HMMediaItem, using resolver: HMItemResolver?, metadataOnly: Bool = false) async throws -> HMMediaItem {
        if let cached = cached(item, requireFormat: !metadataOnly) { return cached }

        let work: Work
        if let existing = pending[item] { work = existing }
        else {
            let metadata = completed[item], session = session
            work = Work(token: UUID(), task: Task {
                if let metadata { return metadataOnly ? metadata : try await Self.detectFormat(metadata, session: session) }
                switch item.source {
                case .reference(let namespace, let id):
                    guard let resolver else { throw HMPlayerError.missingResolver }
                    let raw = try await resolver.resolve(.init(namespace: namespace, id: id))
                    return metadataOnly ? raw : try await Self.detectFormat(raw, session: session)
                case .url(let url, let format):
                    let raw = HMResolvedItem(url: url, format: format)
                    return metadataOnly ? raw : try await Self.detectFormat(raw, session: session)
                }
            })
            pending[item] = work
        }
        do {
            var value = try await work.task.value
            // Promotion may be awaiting a metadata-only task. Probe only when
            // the entry enters a media tier; reuse the resolver result.
            if !metadataOnly, item.resolved(value).format == .auto { value = try await Self.detectFormat(value, session: session) }
            try Task.checkCancellation()
            guard pending[item]?.token == work.token else { throw CancellationError() }
            completed[item] = value; pending[item] = nil; promotions[item] = nil
            return item.resolved(value)
        } catch {
            // Another waiter may already have committed this result.
            if let value = cached(item, requireFormat: !metadataOnly), !Task.isCancelled { return value }
            if pending[item]?.token == work.token { pending[item] = nil; promotions[item] = nil }
            throw error
        }
    }
    func promote(_ item: HMMediaItem) {
        guard let work = pending[item], promotions[item] == nil else { return }
        // Awaiting the existing task from a higher-priority task escalates it;
        // the resolver is neither restarted nor called twice.
        promotions[item] = Task(priority: .userInitiated) { _ = try? await work.task.value }
    }
    static func detectFormat(_ value: HMResolvedItem, session: URLSession = .shared) async throws -> HMResolvedItem {
        guard ["file", "http", "https"].contains(value.url.scheme?.lowercased() ?? "") else { throw HMPlayerError.unsupportedURL }
        guard value.format == .auto, !value.url.isFileURL,
              !["mp4", "m4v", "m3u8"].contains(value.url.pathExtension.lowercased()) else { return value }
        var request = URLRequest(url: value.url); request.httpMethod = "HEAD"; request.timeoutInterval = 20
        let response: URLResponse
        do {
            let (_, head) = try await session.data(for: request)
            guard let http = head as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            response = head
        } catch {
            try Task.checkCancellation()
            // Some signed VOD endpoints reject HEAD. Bound the fallback even if
            // the origin ignores Range: stream at most two bytes, then cancel.
            request.httpMethod = "GET"; request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = session.configuration.protocolClasses
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let (bytes, get) = try await session.bytes(for: request)
            guard let http = get as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw HMPlayerError.resolution("Format detection failed") }
            var iterator = bytes.makeAsyncIterator()
            _ = try await iterator.next(); _ = try await iterator.next()
            response = get
        }
        let mime = response.mimeType?.lowercased() ?? ""
        let hls = mime.contains("mpegurl") || response.url?.pathExtension.lowercased() == "m3u8"
        return HMResolvedItem(url: value.url, format: hls ? .hls : .mp4, poster: value.poster, title: value.title, duration: value.duration)
    }
    func retain(_ window: Set<HMMediaItem>) {
        for (item, work) in pending where !window.contains(item) { work.task.cancel(); pending[item] = nil; promotions[item]?.cancel(); promotions[item] = nil }
    }
    func cancelAll() { retain([]) }
}
