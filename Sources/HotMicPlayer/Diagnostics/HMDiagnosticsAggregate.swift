import Foundation
import Darwin

// Deliberately independent of HMPlaybackEvent/Codable configuration and all identifiers.
struct HMDiagnosticsConfig: Encodable, Equatable, Sendable {
    let content_players: Int, startup_bps: Int, ahead_count: Int, behind_count: Int
    let entry_bytes: Int, entry_ms: Int
    let adaptive: Bool
    let trigger: String

    init?(_ c: HMPlayerConfiguration) {
        guard c.startupPeakBitRate.isFinite, (0...1_000_000_000).contains(c.startupPeakBitRate),
              (1...16).contains(c.poolSize), (0...32).contains(c.prefetch.ahead),
              (0...32).contains(c.prefetch.behind), (0...HMPrefetchPolicy.maximumBytesPerItem).contains(c.prefetch.bytesPerItem) else { return nil }
        var ms = 0, bytes = c.prefetch.bytesPerItem
        if let seconds = c.prefetch.secondsPerItem {
            guard seconds.isFinite else { return nil }
            if seconds <= 0 { bytes = 0 }
            else if bytes > 0 {
                let value = ceil(seconds * 1000)
                guard value.isFinite, value <= 60_000 else { return nil }
                ms = Int(value)
            }
        }
        content_players = min(4, c.poolSize); startup_bps = Int(c.startupPeakBitRate.rounded())
        ahead_count = min(8, c.prefetch.ahead); behind_count = min(8, c.prefetch.behind)
        entry_bytes = bytes; entry_ms = ms; adaptive = c.adaptive; trigger = c.activationTrigger.rawValue
    }
}

struct HMDiagnosticsAggregate: Encodable, Sendable {
    struct OS: Encodable, Sendable { let major: Int, minor: Int, patch: Int }
    struct Playback: Encodable, Sendable {
        var attempted = 0, first_frames = 0, ended_before_first_frame = 0
    }
    struct Stalls: Encodable, Sendable { var count = 0, total_duration_ms = 0 }
    let schema_version = 1
    let sdk_version = HotMicPlayer.version
    let os_version: OS
    let hardware_model: String
    let sample_rate: Double
    var window_duration_ms = 60_000
    let config: HMDiagnosticsConfig
    var playback = Playback()
    var startup_buckets = [Int](repeating: 0, count: 8)
    var moving_start_buckets = [Int](repeating: 0, count: 8)
    var stalls = Stalls()
    // Overflow invalidates the whole window; never encode an invented clipped observation.
    var invalid = false
    enum CodingKeys: String, CodingKey {
        case schema_version, sdk_version, os_version, hardware_model, sample_rate, window_duration_ms
        case config, playback, startup_buckets, moving_start_buckets, stalls
    }
    init(config: HMDiagnosticsConfig, rate: Double) {
        self.config = config; sample_rate = rate
        let os = ProcessInfo.processInfo.operatingSystemVersion
        os_version = OS(major: os.majorVersion, minor: os.minorVersion, patch: os.patchVersion)
        invalid = ![os.majorVersion, os.minorVersion, os.patchVersion].allSatisfy { (0...99).contains($0) }
        #if targetEnvironment(simulator)
        hardware_model = "simulator"
        #else
        var info = utsname(); uname(&info)
        let machine = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        hardware_model = machine.range(of: "^(iPhone|iPad|iPod)[0-9]{1,2},[0-9]{1,2}$", options: .regularExpression) == nil ? "unknown" : machine
        #endif
    }
    static func bucket(_ ms: Double) -> Int? {
        guard ms.isFinite, ms >= 0 else { return nil }
        if ms < 100 { return 0 }; if ms < 150 { return 1 }; if ms < 250 { return 2 }
        if ms < 500 { return 3 }; if ms < 1000 { return 4 }; if ms < 2000 { return 5 }
        return ms < 5000 ? 6 : 7
    }
}
