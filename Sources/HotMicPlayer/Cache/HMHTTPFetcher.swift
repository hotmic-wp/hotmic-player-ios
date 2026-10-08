#if !os(macOS)
import Foundation

/// Block-based URLSession delegate with bounded memory and explicit cancellation.
/// A Range-ignoring origin may supply a prefix at offset zero; nonzero requests
/// are rejected by the proxy rather than returning the wrong media bytes.
final class HMHTTPFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Result { let data: Data; let response: HTTPURLResponse; let received: Int }
    struct Failure: Error { let underlying: Error; let received: Int }
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result, Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var data = Data()
    private var response: HTTPURLResponse?
    private var received = 0
    private let limit: Int
    private var cancelled = false
    init(limit: Int) { self.limit = limit }
    func load(_ request: URLRequest) async throws -> Result {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                lock.lock()
                if cancelled { lock.unlock(); c.resume(throwing: CancellationError()); return }
                continuation = c
                let config = URLSessionConfiguration.ephemeral
                config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
                config.timeoutIntervalForRequest = 20
                let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                session = s; let t = s.dataTask(with: request); task = t
                lock.unlock(); t.resume()
            }
        } onCancel: { self.cancel() }
    }
    private func cancel() {
        lock.lock(); cancelled = true; let t = task; lock.unlock(); t?.cancel()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 206 else { completionHandler(.cancel); return }
        self.response = http; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
        received += bytes.count
        data.append(bytes.prefix(max(0, limit - data.count)))
        if data.count >= limit { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let c = continuation; continuation = nil; let wasCancelled = cancelled; lock.unlock()
        if !wasCancelled, let response, data.count >= min(limit, max(0, Int(response.expectedContentLength))), !data.isEmpty {
            c?.resume(returning: Result(data: data, response: response, received: received))
        } else { c?.resume(throwing: Failure(underlying: wasCancelled ? CancellationError() : error ?? URLError(.badServerResponse), received: received)) }
        session.finishTasksAndInvalidate(); self.session = nil; self.task = nil
    }
}
#endif
