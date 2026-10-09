import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Anything that wants playback telemetry implements this.
///
/// Sinks are called on the main actor, in registration order, and must not
/// block. Beacon-style back ends (Mux, Conviva) additionally need a handle on
/// the concrete `AVPlayerLayer`; that is what `attach`/`detach` are for.
@MainActor
public protocol HMAnalyticsSink: AnyObject {
    /// Stable name, used for de-duplication and in the sample app's UI.
    var sinkName: String { get }

    /// Receives one telemetry event on the main actor.
    func handle(_ event: HMPlaybackEvent, item: HMMediaItem)

    #if canImport(AVFoundation)
    /// Called when a pooled player becomes responsible for `item`.
    /// - Parameter playerKey: stable identifier for the *pooled player*, not the item.
    func attach(playerLayer: AVPlayerLayer, playerKey: String, item: HMMediaItem)
    /// Called when the pooled player is recycled onto a different item.
    func videoChange(playerKey: String, item: HMMediaItem)
    /// Ends monitoring for a released pooled player.
    func detach(playerKey: String)
    #endif
}

public extension HMAnalyticsSink {
    #if canImport(AVFoundation)
    /// Default sinks do not attach to native players.
    func attach(playerLayer: AVPlayerLayer, playerKey: String, item: HMMediaItem) {}
    /// Default sinks do not track recycled native players.
    func videoChange(playerKey: String, item: HMMediaItem) {}
    /// Ends monitoring for a released pooled player.
    func detach(playerKey: String) {}
    #endif
}
