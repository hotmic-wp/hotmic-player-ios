import Foundation
import AVFoundation
import HotMicPlayer

/// Default bridge: forwards everything to a callback instead of Mux's servers.
/// Used by the sample app to render the exact beacons Mux would receive.
@MainActor
final class DemoMuxBridge: HMMuxBridge {

    /// One recorded Mux bridge call.
    public struct Beacon: Identifiable, Sendable {
        /// Stable identity for this value.
        public let id = UUID()
        /// Mux bridge method represented by this beacon.
        public let call: String
        /// Player name sent to Mux.
        public let playerName: String
        /// Flattened Mux schema fields.
        public let payload: [String: String]
        /// Wall-clock occurrence time.
        public let timestamp = Date()
    }

    /// Recent recorded Mux calls, bounded by capacity.
    public private(set) var beacons: [Beacon] = []
    /// Optional callback invoked for each recorded Mux call.
    public var onBeacon: ((Beacon) -> Void)?
    private let capacity: Int

    /// Creates Mux configuration, video metadata or a bounded logging bridge.
    public init(capacity: Int = 100) { self.capacity = capacity }

    private func record(_ call: String, _ playerName: String, _ payload: [String: String]) {
        let beacon = Beacon(call: call, playerName: playerName, payload: payload)
        beacons.insert(beacon, at: 0)
        if beacons.count > capacity { beacons.removeLast(beacons.count - capacity) }
        onBeacon?(beacon)
    }

    #if canImport(AVFoundation)
    /// Records the player-layer monitoring call.
    public func monitor(playerLayer: AVPlayerLayer, playerName: String, environment: HMMuxEnvironment, video: HMMuxVideoData) {
        record("monitorAVPlayerLayer", playerName, environment.payload.merging(video.payload) { _, new in new })
    }
    #endif

    /// Updates analytics metadata when a player is recycled.
    public func videoChange(playerName: String, video: HMMuxVideoData) {
        record("videoChangeForPlayer", playerName, video.payload)
    }

    /// Records teardown of a monitored player.
    public func destroy(playerName: String) {
        record("destroyPlayer", playerName, [:])
    }

    /// Records a playback error for the named player.
    public func dispatchError(playerName: String, code: String, message: String) {
        record("dispatchError", playerName, ["player_error_code": code, "player_error_message": message])
    }
}
