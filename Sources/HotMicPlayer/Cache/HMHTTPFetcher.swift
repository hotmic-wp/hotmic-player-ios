#if !os(macOS)
import Foundation

/// One connection pool for every strategy. A task delegate owns only its
/// request, never invalidates the shared session, and streams with backpressure.
final class HMHTTPFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Result { let data: Data; let response: HTTPURLResponse; let received: Int }
    struct Failure: Error { let underlying: Error; let received: Int }
    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        queue.name = "com.hotmic.http.delegate"
        return URLSession(configuration: config, delegate: nil, delegateQueue: queue)
    }()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result, Error>?
    private var task: URLSessionDataTask?
    private var data = Data()
    private var response: HTTPURLResponse?
    private var received = 0
    private let limit: Int
    private var cancelled = false
    private var pending: Task<Void, Never>?
    private var streamingError: Error?
    private let headers: (@Sendable (HTTPURLResponse) async throws -> Void)?
    private let bytes: (@Sendable (Data) async throws -> Void)?
    init(limit: Int, headers: (@Sendable (HTTPURLResponse) async throws -> Void)? = nil,
         bytes: (@Sendable (Data) async throws -> Void)? = nil) {
        self.limit = limit; self.headers = headers; self.bytes = bytes
    }
    func load(_ request: URLRequest) async throws -> Result {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                lock.lock()
                if cancelled { lock.unlock(); c.resume(throwing: CancellationError()); return }
                continuation = c
                let t = Self.sharedSession.dataTask(with: request); t.delegate = self; task = t
                lock.unlock(); t.resume()
            }
        } onCancel: { self.cancel() }
    }
    private func cancel() { lock.lock(); cancelled = true; let t = task; lock.unlock(); t?.cancel() }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, headers != nil || (200...299).contains(http.statusCode) else { completionHandler(.cancel); return }
        self.response = http
        if let headers {
            pending = Task {
                do { try await headers(http); completionHandler(.allow) }
                catch { lock.lock(); streamingError = error; lock.unlock(); completionHandler(.cancel) }
            }
        } else { completionHandler(.allow) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        received += chunk.count
        if let bytes {
            dataTask.suspend()
            let previous = pending
            pending = Task {
                await previous?.value
                do { try await bytes(chunk); dataTask.resume() }
                catch { lock.lock(); streamingError = error; lock.unlock(); dataTask.cancel() }
            }
        } else {
            data.append(chunk.prefix(max(0, limit - data.count)))
            let expected = response?.expectedContentLength ?? -1
            if data.count >= limit && (expected < 0 || expected > Int64(limit)) { dataTask.cancel() }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let previous = pending
        Task {
            await previous?.value
            lock.lock(); let c = continuation; continuation = nil; let wasCancelled = cancelled; let streamError = streamingError; lock.unlock()
            if let response, !wasCancelled, streamError == nil,
               (bytes != nil ? error == nil : (!data.isEmpty && (data.count >= limit || (error == nil && data.count >= max(0, Int(response.expectedContentLength)))))) {
                c?.resume(returning: Result(data: data, response: response, received: received))
            } else { c?.resume(throwing: Failure(underlying: wasCancelled ? CancellationError() : streamError ?? error ?? URLError(.badServerResponse), received: received)) }
            self.task = nil; pending = nil
        }
    }
}
#endif
