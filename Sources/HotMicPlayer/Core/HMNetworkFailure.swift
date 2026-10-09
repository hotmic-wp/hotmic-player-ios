import Foundation

/// Connectivity failures remain retryable even when wrapped by AVFoundation.
enum HMNetworkFailure {
    static func isTransient(_ error: Error?) -> Bool {
        guard let error else { return false }
        return isTransient(error as NSError, depth: 0)
    }
    private static func isTransient(_ error: NSError, depth: Int) -> Bool {
        guard depth < 8 else { return false }
        if error.domain == NSURLErrorDomain {
            switch URLError.Code(rawValue: error.code) {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .internationalRoamingOff, .dataNotAllowed: return true
            default: break
            }
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           isTransient(underlying, depth: depth + 1) { return true }
        let errors = error.userInfo["NSMultipleUnderlyingErrors"] as? [NSError] ?? []
        return errors.contains { isTransient($0, depth: depth + 1) }
    }
}

/// Unbounded attempts with bounded waits; connectivity errors never spend the terminal budget.
/// Each wait is jittered by ±25% so many clients (or many entries) recovering from the same
/// server outage spread their retries instead of arriving as one synchronized burst.
struct HMNetworkRetry {
    static let jitter: ClosedRange<Double> = 0.75...1.25
    var attempts = 0
    var nextAttempt: TimeInterval = 0
    /// Base delay before jitter: 1, 2, 4, 8, 16, then 30 seconds.
    var baseDelay: TimeInterval { attempts == 0 ? 0 : min(30, pow(2, Double(attempts - 1))) }
    mutating func failed(at now: TimeInterval, jitter: Double = Double.random(in: HMNetworkRetry.jitter)) {
        attempts = min(6, attempts + 1)
        nextAttempt = now + baseDelay * min(Self.jitter.upperBound, max(Self.jitter.lowerBound, jitter))
    }
}

#if canImport(Network) && !os(macOS)
import Network

/// Owned per player; never changes the host's interfaces or network settings.
final class HMConnectivityMonitor {
    private let monitor = NWPathMonitor()
    init(changed: @escaping @Sendable (Bool) -> Void) {
        monitor.pathUpdateHandler = { changed($0.status == .satisfied) }
        monitor.start(queue: DispatchQueue(label: "com.hotmic.player.connectivity"))
    }
    func cancel() { monitor.cancel() }
    deinit { monitor.cancel() }
}
#endif
