import AVFoundation
import Observation
import SwiftUI
import HotMicPlayer

/// Everything the control panel can change at runtime.
///
/// The point of the sample app is to make SDK tuning *felt*, so every knob here
/// maps to a real configuration value rather than a cosmetic toggle.
@MainActor
@Observable
final class DemoSettings {

    enum Preset: String, CaseIterable, Identifiable {
        case instantStart, balanced, highQuality
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .instantStart: "Instant start"
            case .balanced: "Balanced"
            case .highQuality: "High quality"
            }
        }
        var configuration: HMPlayerConfiguration {
            switch self {
            case .instantStart: .instantStart
            case .balanced: .default
            case .highQuality: .highQuality
            }
        }
        var blurb: String {
            switch self {
            case .instantStart: "900,000 bits/s for 3 startup seconds; two players with a 3/1 data window."
            case .balanced: "Two players, fixed 3 ahead / 1 behind; target 4s, cap 8 MiB per entry."
            case .highQuality: "Unrestricted startup, 20s steady buffer; two players and the same fixed window."
            }
        }
    }

    enum PrefetchChoice: String, CaseIterable, Identifiable {
        case off, next, balanced, aggressive, hybrid
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .hybrid: "3 / 1 data"
            case .off: "Off"
            case .next: "1 ahead"
            case .balanced: "2 / 1"
            case .aggressive: "3 / 2"
            }
        }
        var policy: HMPrefetchPolicy {
            switch self {
            case .hybrid: HMPrefetchPolicy()
            case .off: .off
            case .next: .nextOnly
            case .balanced: .balanced
            case .aggressive: .aggressive
            }
        }
    }

    var preset: Preset = .balanced { didSet { syncFromPreset() } }
    var prefetch: PrefetchChoice = .hybrid { didSet { rebuildConfiguration() } }
    var poolSize: Int = 2 { didSet { rebuildConfiguration() } }
    var loops: Bool = true { didSet { rebuildConfiguration() } }

    var transition: HMPageTransition = .none
    var fillsScreen: Bool = true
    var showsHUD: Bool = true
    var showsOverlays: Bool = true
    #if DEBUG
    let moderation = ModerationDebugSession()
    #endif

    var gravity: AVLayerVideoGravity { fillsScreen ? .resizeAspectFill : .resizeAspect }

    /// Set by `DemoRootView` once the controller exists.
    var applyConfiguration: ((HMPlayerConfiguration) -> Void)?

    func rebuildConfiguration() {
        var configuration = preset.configuration
        configuration.prefetch = prefetch.policy
        configuration.poolSize = poolSize
        configuration.loops = loops
        applyConfiguration?(configuration)
    }

    /// Keeps the panel honest when a preset changes the derived values.
    func syncFromPreset() {
        let configuration = preset.configuration
        poolSize = configuration.poolSize
        prefetch = PrefetchChoice.allCases.first { $0.policy == configuration.prefetch } ?? .balanced
    }
}
