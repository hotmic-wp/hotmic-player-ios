import AVFoundation
import Observation
import SwiftUI
@_spi(Benchmark) import HotMicPlayer

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
            case .instantStart: "Caps the first segment at 900 kbps and warms 3 ahead. Fastest swipe-to-frame."
            case .balanced: "Two players, 5 ahead / 1 back in disk cache. The shipping default."
            case .highQuality: "No bitrate cap, 20s buffers, only 1 preloaded. Best picture, slowest start."
            }
        }
    }

    enum PrefetchChoice: String, CaseIterable, Identifiable {
        case off, next, balanced, aggressive, hybrid
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .hybrid: "5 / 1 data"
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
