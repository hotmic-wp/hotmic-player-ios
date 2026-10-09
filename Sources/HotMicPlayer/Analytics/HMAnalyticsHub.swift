import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Fan-out point between the player core and any number of analytics sinks.
///
/// The core never knows about Mux; it only ever talks to the hub.
@MainActor
public final class HMAnalyticsHub {

    /// Registered sinks, called in registration order.
    private(set) public var sinks: [HMAnalyticsSink] = []

    /// Creates an analytics hub with optional initial sinks.
    public init(sinks: [HMAnalyticsSink] = []) {
        self.sinks = sinks
    }

    /// Registers a sink once by its stable name.
    public func add(_ sink: HMAnalyticsSink) {
        guard !sinks.contains(where: { $0.sinkName == sink.sinkName }) else { return }
        sinks.append(sink)
    }

    /// Removes every sink with the supplied name.
    public func remove(named name: String) {
        sinks.removeAll { $0.sinkName == name }
    }

    func emit(_ event: HMPlaybackEvent, item: HMMediaItem) {
        for sink in sinks { sink.handle(event, item: item) }
    }

    #if canImport(AVFoundation)
    func attach(playerLayer: AVPlayerLayer, playerKey: String, item: HMMediaItem) {
        for sink in sinks { sink.attach(playerLayer: playerLayer, playerKey: playerKey, item: item) }
    }

    func videoChange(playerKey: String, item: HMMediaItem) {
        for sink in sinks { sink.videoChange(playerKey: playerKey, item: item) }
    }

    func detach(playerKey: String) {
        for sink in sinks { sink.detach(playerKey: playerKey) }
    }
    #endif
}
