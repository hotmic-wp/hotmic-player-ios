import Foundation

/// Optional aggregate performance delivery. No viewer identity is used.
/// Use from any task; mutate only an exclusively owned value.
public struct HMPlayerDiagnosticsConfiguration: Sendable {
    /// Platform HTTPS base URL, without credentials, query or fragment.
    public var baseURL: URL
    /// Platform app key; never a viewer token. Only used in the apikey header.
    public var appKey: String
    /// Percent of player lifetimes selected, default 1. Invalid values disable collection.
    public var samplingPercent: Double

    /// Creates an opt-in policy. Passing nil to HMPlayer.setDiagnostics disables it.
    public init(baseURL: URL, appKey: String, samplingPercent: Double = 1) {
        self.baseURL = baseURL; self.appKey = appKey; self.samplingPercent = samplingPercent
    }

    var endpoint: URL? {
        guard let parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let host = parts.host, !host.isEmpty,
              parts.scheme == "https" || (parts.scheme == "http" && ["127.0.0.1", "[::1]", "::1"].contains(host)),
              appKey.utf8.count >= 1, appKey.utf8.count <= 128,
              appKey.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }),
              samplingPercent.isFinite, (0.0001...100).contains(samplingPercent) else { return nil }
        return baseURL.appendingPathComponent("v2/player/diagnostics")
    }
}
