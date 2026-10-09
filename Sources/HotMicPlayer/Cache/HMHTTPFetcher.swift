#if !os(macOS)
import Foundation

/// Locked per-response state, separate speculative connection pool and bounded streaming backpressure.
final class HMHTTPFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Result { let data: Data; let response: HTTPURLResponse; let received: Int; let delivered: Int }
    struct Failure: Error { let underlying: Error; let received: Int }
    private static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20; config.httpMaximumConnectionsPerHost = 8
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        queue.name = "com.hotmic.http.delegate"
        return URLSession(configuration: config, delegate: nil, delegateQueue: queue)
    }
    private static let playbackSession = session()
    private static let prefetchSession = session()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result, Error>?
    private var task: URLSessionDataTask?
    private var data = Data()
    private var response: HTTPURLResponse?
    private var received = 0
    private var delivered = 0
    private var reachedStreamLimit = false
    private var beganAt = 0.0
    private var receiveAt = 0.0
    private var sampleBytes = 0
    private var sampleSeconds = 0.0
    private let measurement: (@Sendable (Int, Double, Double?) -> Void)?
    private let limit: Int
    private let priority: Float
    private var cancelled = false
    private var pending: Task<Void, Never>?
    private var streamingError: Error?
    private var watchdog: DispatchWorkItem?
    private var watchdogID = UUID()
    private let headers: (@Sendable (HTTPURLResponse) async throws -> Void)?
    private let bytes: (@Sendable (Data) async throws -> Void)?
    init(limit: Int, priority: Float = URLSessionTask.highPriority,
         measurement: (@Sendable (Int, Double, Double?) -> Void)? = nil,
         headers: (@Sendable (HTTPURLResponse) async throws -> Void)? = nil,
         bytes: (@Sendable (Data) async throws -> Void)? = nil) {
        self.limit = limit; self.priority = priority; self.measurement = measurement; self.headers = headers; self.bytes = bytes
    }
    func load(_ request: URLRequest) async throws -> Result {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                lock.lock()
                if cancelled { lock.unlock(); c.resume(throwing: CancellationError()); return }
                continuation = c
                var request = request
                // URLSession's timeout can include time spent deliberately suspended.
                // For streamed responses, the 20s inactivity watchdog below runs only
                // while upstream work is allowed. Full-buffer pauses have no deadline.
                if bytes != nil { request.timeoutInterval = 24 * 60 * 60 }
                let session = priority == URLSessionTask.lowPriority ? Self.prefetchSession : Self.playbackSession
                let t = session.dataTask(with: request); t.delegate = self; t.priority = priority; task = t
                beganAt = ProcessInfo.processInfo.systemUptime; receiveAt = beganAt
                armWatchdogLocked(); t.resume(); lock.unlock()
            }
        } onCancel: { self.cancel() }
    }
    private func cancel() {
        lock.lock(); cancelled = true; watchdog?.cancel(); watchdogID = UUID(); task?.cancel(); pending?.cancel(); lock.unlock()
    }
    /// Caller holds lock. The generation prevents an already-enqueued expired timer from cancelling resumed work.
    private func armWatchdogLocked() {
        watchdog?.cancel(); let id = UUID(); watchdogID = id
        guard bytes != nil, !cancelled, task != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            lock.lock(); defer { lock.unlock() }
            guard watchdogID == id, task != nil else { return }
            streamingError = URLError(.timedOut); task?.cancel()
        }
        watchdog = work; DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20, execute: work)
    }
    private func suspendWatchdogLocked() { watchdog?.cancel(); watchdogID = UUID() }
    private func streamFailed(_ error: Error) { lock.lock(); streamingError = error; task?.cancel(); lock.unlock() }
    private func resumeStream(_ dataTask: URLSessionDataTask, atLimit: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, task === dataTask else { return }
        if atLimit { dataTask.cancel(); return }
        receiveAt = ProcessInfo.processInfo.systemUptime
        armWatchdogLocked(); dataTask.resume()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { completionHandler(.cancel); return }
        lock.lock(); self.response = http
        let now = ProcessInfo.processInfo.systemUptime
        measurement?(0, 0, max(0, now - beganAt)); receiveAt = now
        if let headers {
            suspendWatchdogLocked()
            pending = Task {
                do { try await headers(http); self.headersCompleted(); completionHandler(.allow) }
                catch { self.streamFailed(error); completionHandler(.cancel) }
            }
            lock.unlock()
        } else { lock.unlock(); completionHandler(.allow) }
    }
    private func headersCompleted() { lock.lock(); receiveAt = ProcessInfo.processInfo.systemUptime; armWatchdogLocked(); lock.unlock() }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        received += chunk.count
        let now = ProcessInfo.processInfo.systemUptime
        sampleBytes += chunk.count; sampleSeconds += max(0, now - receiveAt); receiveAt = now
        if sampleSeconds >= 0.25 { flushMeasurementLocked() }
        if let bytes {
            dataTask.suspend(); suspendWatchdogLocked()
            let accepted = limit == Int.max ? chunk : Data(chunk.prefix(max(0, limit - delivered)))
            delivered += accepted.count
            let atLimit = delivered >= limit
            reachedStreamLimit = atLimit
            let previous = pending
            pending = Task {
                await previous?.value
                do {
                    try Task.checkCancellation()
                    if !accepted.isEmpty { try await bytes(accepted) }
                    self.resumeStream(dataTask, atLimit: atLimit)
                }
                catch { self.streamFailed(error) }
            }
        } else {
            data.append(chunk.prefix(max(0, limit - data.count)))
            let expected = response?.expectedContentLength ?? -1
            if data.count >= limit && (expected < 0 || expected > Int64(limit)) { dataTask.cancel() }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let previous = pending; suspendWatchdogLocked(); lock.unlock()
        Task { await previous?.value; self.complete(error) }
    }
    private func flushMeasurementLocked() {
        // Tiny manifests and a final delegate burst are latency observations,
        // not capacity samples. Avoid an arbitrarily high bytes/delta estimate.
        if sampleBytes >= 32 * 1024, sampleSeconds >= 0.01 { measurement?(sampleBytes, sampleSeconds, nil) }
        sampleBytes = 0; sampleSeconds = 0
    }
    private func complete(_ error: Error?) {
        lock.lock()
        flushMeasurementLocked()
        let c = continuation; continuation = nil
        let wasCancelled = cancelled, streamError = streamingError, response = response, data = data, received = received
        let delivered = delivered, limitCancellation = reachedStreamLimit && (error as NSError?)?.code == NSURLErrorCancelled
        task = nil; pending = nil; suspendWatchdogLocked(); lock.unlock()
        if let response, !wasCancelled, streamError == nil,
           (bytes != nil ? (error == nil || limitCancellation) : (!data.isEmpty && (data.count >= limit || (error == nil && data.count >= max(0, Int(response.expectedContentLength)))))) {
            c?.resume(returning: Result(data: data, response: response, received: received, delivered: bytes != nil ? delivered : data.count))
        } else { c?.resume(throwing: Failure(underlying: wasCancelled ? CancellationError() : streamError ?? error ?? URLError(.badServerResponse), received: received)) }
    }
}
#endif
