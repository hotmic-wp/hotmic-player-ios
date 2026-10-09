import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Adapts HotMicPlayer's normalised events onto Mux Data's player lifecycle.
///
/// The important detail for a *vertical feed*: Mux bills and reports per "view",
/// and a recycled `AVPlayer` must call `videoChange` rather than being torn down
/// and re-monitored. This sink tracks pooled players by key and does exactly
/// that, which is the part teams usually get wrong when they build a feed.
@MainActor
public final class HMMuxAnalyticsSink: HMAnalyticsSink {

    /// Stable sink identifier used by the hub for deduplication.
    public let sinkName = "mux"
    /// Mux configuration used for new attachments.
    public var environment: HMMuxEnvironment
    private let bridge: HMMuxBridge

    /// playerKey -> the item that player is currently reporting on.
    private var monitoredItems: [String: String] = [:]
    /// Durations learned from the player, so `video_duration` is accurate.
    private var knownDurations: [String: TimeInterval] = [:]

    /// Creates a Mux analytics sink using a host-provided bridge.
    public init(environment: HMMuxEnvironment, bridge: HMMuxBridge) {
        self.environment = environment
        self.bridge = bridge
    }

    /// Convenience initialiser that logs beacons instead of shipping them.
    @_spi(Benchmark) public convenience init(environmentKey: String, viewerUserID: String? = nil) {
        self.init(
            environment: HMMuxEnvironment(environmentKey: environmentKey, viewerUserID: viewerUserID),
            bridge: HMLoggingMuxBridge()
        )
    }

    private func videoData(for item: HMMediaItem) -> HMMuxVideoData {
        HMMuxVideoData(item: item, duration: knownDurations[item.id])
    }

    // MARK: - HMAnalyticsSink

    #if canImport(AVFoundation)
    /// Attaches an analytics backend to a pooled player layer.
    public func attach(playerLayer: AVPlayerLayer, playerKey: String, item: HMMediaItem) {
        guard monitoredItems[playerKey] == nil else {
            // Already monitored: this is a recycle, not a fresh player.
            videoChange(playerKey: playerKey, item: item)
            return
        }
        monitoredItems[playerKey] = item.id
        bridge.monitor(
            playerLayer: playerLayer,
            playerName: playerKey,
            environment: environment,
            video: videoData(for: item)
        )
    }

    /// Updates analytics metadata when a player is recycled.
    public func videoChange(playerKey: String, item: HMMediaItem) {
        // A speculative node can recycle before it was ever attached.
        guard monitoredItems[playerKey] != nil else { return }
        guard monitoredItems[playerKey] != item.id else { return }
        monitoredItems[playerKey] = item.id
        bridge.videoChange(playerName: playerKey, video: videoData(for: item))
    }

    /// Ends analytics monitoring for a pooled player.
    public func detach(playerKey: String) {
        guard monitoredItems.removeValue(forKey: playerKey) != nil else { return }
        bridge.destroy(playerName: playerKey)
    }
    #endif

    /// Consumes one telemetry event on the main actor.
    public func handle(_ event: HMPlaybackEvent, item: HMMediaItem) {
        if let duration = event.metrics["duration_s"], duration > 0 {
            knownDurations[item.id] = duration
        }
        guard let playerKey = event.properties["player_key"] else { return }

        switch event.kind {
        case .error:
            bridge.dispatchError(
                playerName: playerKey,
                code: event.properties["error_code"] ?? "-1",
                message: event.properties["error_message"] ?? "unknown"
            )
        case .viewStart:
            // A pooled player that is already monitored just changed content.
            videoChange(playerKey: playerKey, item: item)
        default:
            // Every other signal (play/pause/rebuffer/variant) is derived by the
            // Mux SDK straight from the AVPlayer it is monitoring, so there is
            // nothing to forward. They are still surfaced to other sinks.
            break
        }
    }
}
