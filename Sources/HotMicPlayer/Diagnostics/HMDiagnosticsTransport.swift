import Foundation

// One reserved utility job/request. Only state/reference publication is locked;
// framework work runs outside locks. Cancel-before-resume remains cancelled.
final class HMDiagnosticsCadence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval
    init(lastAttempt: TimeInterval = -.infinity) { value = lastAttempt }
    var lastAttempt: TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func reserve(at now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard now - value >= 60 else { return false }
        value = now; return true
    }
}

final class HMDiagnosticsTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let work = DispatchQueue(label: "com.hotmic.player.diagnostics", qos: .utility)
    private var session: URLSession?
    private var request: URLSessionDataTask?
    private var stopped = false
    private var reserved = false
    private let endpoint: URL
    private let appKey: String
    private let cadence: HMDiagnosticsCadence
    private let protocolClasses: [AnyClass]?
    init(endpoint: URL, appKey: String, protocolClasses: [AnyClass]? = nil, cadence: HMDiagnosticsCadence = HMDiagnosticsCadence()) {
        self.endpoint = endpoint; self.appKey = appKey; self.protocolClasses = protocolClasses; self.cadence = cadence
        super.init()
    }
    private func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = protocolClasses
        c.httpCookieStorage = nil; c.httpShouldSetCookies = false
        c.urlCredentialStorage = nil; c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 2; c.timeoutIntervalForResource = 2
        c.waitsForConnectivity = false
        c.allowsConstrainedNetworkAccess = false; c.allowsExpensiveNetworkAccess = false
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .utility
        return URLSession(configuration: c, delegate: self, delegateQueue: queue)
    }
    var busy: Bool { lock.lock(); defer { lock.unlock() }; return reserved }
    @discardableResult func submit(_ snapshot: HMDiagnosticsAggregate) -> Bool {
        lock.lock()
        guard !stopped, !reserved else { lock.unlock(); return false }
        reserved = true; lock.unlock()
        let expires = ProcessInfo.processInfo.systemUptime + 2
        work.async { [weak self] in
            guard let self else { return }
            assert(!Thread.isMainThread)
            let data = try? JSONEncoder().encode(snapshot)
            guard let data, data.count <= 8192 else {
                self.lock.lock(); self.reserved = false; self.lock.unlock(); return
            }
            self.lock.lock(); let stopped = self.stopped; self.lock.unlock()
            guard !stopped, ProcessInfo.processInfo.systemUptime < expires else {
                self.lock.lock(); self.reserved = false; self.lock.unlock(); return
            }
            var r = URLRequest(url: self.endpoint, timeoutInterval: 2)
            r.httpMethod = "POST"; r.httpBody = data
            // Override CFNetwork's locale-dependent negotiation with fixed values.
            r.setValue("", forHTTPHeaderField: "Accept-Language")
            r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            r.setValue(self.appKey, forHTTPHeaderField: "apikey")
            r.setValue("HotMicPlayer", forHTTPHeaderField: "User-Agent")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue("application/json", forHTTPHeaderField: "Accept")
            let session = self.makeSession()
            let task = session.dataTask(with: r)
            self.lock.lock()
            // Cadence is checked after encoding/session construction, at task admission.
            // It survives cancelled transports and disable/re-enable on the same player.
            let admitted = !self.stopped && ProcessInfo.processInfo.systemUptime < expires &&
                self.cadence.reserve(at: ProcessInfo.processInfo.systemUptime)
            if admitted { self.session = session; self.request = task }
            else { self.reserved = false }
            self.lock.unlock()
            if admitted { task.resume() }
            else { task.cancel(); session.invalidateAndCancel() }
        }
        return true
    }
    func cancel() {
        lock.lock(); stopped = true; reserved = false
        let task = request, owned = session
        request = nil; session = nil
        lock.unlock()
        task?.cancel(); owned?.invalidateAndCancel()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // All statuses are terminal. Acknowledgment/body are deliberately unobserved.
        completionHandler(.cancel)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); request = nil; reserved = false
        let owned = self.session; self.session = nil; lock.unlock()
        owned?.finishTasksAndInvalidate()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil); task.cancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // System trust evaluation is necessary for HTTPS; no HTTP credential negotiation.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
}
