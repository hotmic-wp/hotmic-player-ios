import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Anything that wants playback telemetry implements this.
///
/// Sinks are called on the main actor, in registration order, and must not
/// block. Beacon-style back ends (Mux, Conviva) additionally need a handle on
/// the concrete `AVPlayerLayer`; that is what `attach`/`detach` are for.
///
/// Access on the main actor.
@MainActor
public protocol HMAnalyticsSink: AnyObject {
    /// Stable name, used for de-duplication and in the sample app's UI.
    ///
    /// Access on the main actor.
    var sinkName: String { get }

    /// Receives one telemetry event on the main actor.
    ///
    /// Access on the main actor.
    func handle(_ event: HMPlaybackEvent, item: HMMediaItem)

    #if canImport(AVFoundation)
    /// Called when a pooled player becomes responsible for `item`.
    /// - Parameter playerLayer: Native layer to monitor for this attachment.
    /// - Parameter item: Media metadata for the attached player.
    /// - Parameter playerKey: stable identifier for the *pooled player*, not the item.
    ///
    /// Access on the main actor.
    func attach(playerLayer: AVPlayerLayer, playerKey: String, item: HMMediaItem)
    /// Called when the pooled player is recycled onto a different item.
    ///
    /// Access on the main actor.
    func videoChange(playerKey: String, item: HMMediaItem)
    /// Ends monitoring for a released pooled player.
    ///
    /// Access on the main actor.
    func detach(playerKey: String)
    #endif
}

public extension HMAnalyticsSink {
    #if canImport(AVFoundation)
    /// Default sinks do not attach to native players.
    ///
    /// Access on the main actor.
    func attach(playerLayer: AVPlayerLayer, playerKey: String, item: HMMediaItem) {}
    /// Default sinks do not track recycled native players.
    ///
    /// Access on the main actor.
    func videoChange(playerKey: String, item: HMMediaItem) {}
    /// Ends monitoring for a released pooled player.
    ///
    /// Access on the main actor.
    func detach(playerKey: String) {}
    #endif
}
