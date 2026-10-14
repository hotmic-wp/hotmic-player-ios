import Foundation
import Observation

/// Playable VOD metadata returned by a partner resolver.
///
/// Use from any task; mutate only an exclusively owned value.
public struct HMResolvedItem: Sendable, Equatable {
    /// File or HTTP(S) media URL.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let url: URL
    /// Container type, or automatic detection.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let format: HMMediaItem.Format
    /// Optional poster fallback.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let poster: URL?
    /// Optional title fallback.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let title: String?
    /// Optional duration in seconds.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let duration: TimeInterval?
    /// Creates a playable result. Explicit playlist metadata takes precedence over these hints.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public init(url: URL, format: HMMediaItem.Format = .auto, poster: URL? = nil, title: String? = nil, duration: TimeInterval? = nil) {
        self.url = url; self.format = format; self.poster = poster; self.title = title; self.duration = duration
    }
}

/// Resolves opaque references during prefetch. Implementations must cooperate with task cancellation.
///
/// May be called from any task; synchronize implementation state.
public protocol HMItemResolver: Sendable {
    /// Obtains VOD media. Concurrent calls for the same entry are coalesced by the player.
    ///
    /// May be called from any task; synchronize implementation state.
    func resolve(_ ref: HMMediaItem.Reference) async throws -> HMResolvedItem
}

/// Main-actor session cache. Completed results survive window changes; in-flight work does not.
@MainActor @Observable final class HMResolutionStore {
    struct Work {
        let token: UUID
        let task: Task<HMResolvedItem, Error>
        var waiters: [UUID: CheckedContinuation<HMResolvedItem, Error>] = [:]
    }
    private let session: URLSession
    private var signingParameters: [String] = []
    func configure(signingParameters: [String]) {
        guard self.signingParameters != signingParameters else { return }
        cancelAll(); completed.removeAll(); completedTokens.removeAll(); self.signingParameters = signingParameters
    }
    private func identity(_ item: HMMediaItem) -> HMMediaItem.MediaIdentity {
        item.mediaIdentity(ignoring: signingParameters)
    }
    init(session: URLSession = .shared) { self.session = session }
    private var completed: [HMMediaItem.MediaIdentity: HMResolvedItem] = [:]
    private var completedTokens: [HMMediaItem.MediaIdentity: UUID] = [:]
    private var promotions: [HMMediaItem.MediaIdentity: Task<Void, Never>] = [:]
    private var pending: [HMMediaItem.MediaIdentity: Work] = [:]
    private func resolved(_ item: HMMediaItem, with value: HMResolvedItem) -> HMMediaItem {
        let latest = HMResolvedItem(url: item.url ?? value.url, format: value.format,
            poster: value.poster, title: value.title, duration: value.duration)
        return item.resolved(latest)
    }
    func cached(_ item: HMMediaItem, requireFormat: Bool = true) -> HMMediaItem? {
        if let url = item.url, !requireFormat || item.format != .auto || url.isFileURL { return item }
        guard let value = completed[identity(item)].map({ resolved(item, with: $0) }) else { return nil }
        return !requireFormat || value.format != .auto ? value : nil
    }
    func resolve(_ item: HMMediaItem, using resolver: HMItemResolver?, metadataOnly: Bool = false) async throws -> HMMediaItem {
        try Task.checkCancellation()
        if let cached = cached(item, requireFormat: !metadataOnly) { return cached }
        // Capture the key before suspension: configuration may change while a resolver runs.
        let key = identity(item)
        let work: Work
        if let existing = pending[key] { work = existing }
        else {
            let metadata = completed[key].map { value in
                HMResolvedItem(url: item.url ?? value.url, format: value.format,
                    poster: value.poster, title: value.title, duration: value.duration)
            }, session = session
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
            pending[key] = work
            Task(priority: .utility) { [weak self] in
                let result = await work.task.result
                self?.complete(key, token: work.token, result: result)
            }
        }
        let waiter = UUID()
        let value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HMResolvedItem, Error>) in
                guard !Task.isCancelled, pending[key]?.token == work.token else {
                    continuation.resume(throwing: CancellationError()); return
                }
                pending[key]?.waiters[waiter] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(waiter, key: key, token: work.token) }
        }
        try Task.checkCancellation()
        guard completedTokens[key] == work.token || cached(item, requireFormat: !metadataOnly) != nil else { throw CancellationError() }
        // Commit metadata once, then coalesce promotion into a separate format task.
        // A metadata waiter cannot discard another waiter's in-flight format probe.
        if !metadataOnly, item.resolved(value).format == .auto {
            return try await resolve(item, using: resolver)
        }
        return resolved(item, with: value)
    }
    private func complete(_ key: HMMediaItem.MediaIdentity, token: UUID, result: Result<HMResolvedItem, Error>) {
        guard let work = pending[key], work.token == token else { return }
        pending[key] = nil; promotions[key]?.cancel(); promotions[key] = nil
        if case .success(let value) = result {
            completed[key] = value; completedTokens[key] = token
        }
        for waiter in work.waiters.values { waiter.resume(with: result) }
    }
    private func cancelWaiter(_ waiter: UUID, key: HMMediaItem.MediaIdentity, token: UUID) {
        guard pending[key]?.token == token, let continuation = pending[key]?.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(throwing: CancellationError())
        if pending[key]?.waiters.isEmpty == true { cancel(key) }
    }
    private func cancel(_ key: HMMediaItem.MediaIdentity) {
        guard let work = pending.removeValue(forKey: key) else { return }
        work.task.cancel(); promotions[key]?.cancel(); promotions[key] = nil
        completedTokens[key] = nil
        for waiter in work.waiters.values { waiter.resume(throwing: CancellationError()) }
    }
    func promote(_ item: HMMediaItem) {
        guard let work = pending[identity(item)], promotions[identity(item)] == nil else { return }
        // Awaiting the existing task from a higher-priority task escalates it;
        // the resolver is neither restarted nor called twice.
        promotions[identity(item)] = Task(priority: .userInitiated) { _ = try? await work.task.value }
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
        let media = Set(window.map(identity))
        for key in Array(pending.keys) where !media.contains(key) { cancel(key) }
    }
    func cancelAll() { retain([]) }
}
