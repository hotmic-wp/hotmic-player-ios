import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Environment-level Mux Data configuration (`MUXSDKCustomerPlayerData`).
public struct HMMuxEnvironment: Sendable {
    /// Mux Data environment key supplied by the host.
    public var environmentKey: String
    /// Player name sent to Mux.
    public var playerName: String
    /// SDK version sent to Mux.
    public var playerVersion: String
    /// Optional app-defined viewer ID.
    public var viewerUserID: String?
    /// Optional Mux sub-property ID.
    public var subPropertyID: String?
    /// Optional experiment dimension.
    public var experimentName: String?
    /// `custom_1` ... `custom_5` in the Mux schema.
    public var customDimensions: [String: String]

    /// Creates Mux configuration, video metadata or a bounded logging bridge.
    public init(
        environmentKey: String,
        playerName: String = "HotMicPlayer",
        playerVersion: String = HotMicPlayer.version,
        viewerUserID: String? = nil,
        subPropertyID: String? = nil,
        experimentName: String? = nil,
        customDimensions: [String: String] = [:]
    ) {
        self.environmentKey = environmentKey
        self.playerName = playerName
        self.playerVersion = playerVersion
        self.viewerUserID = viewerUserID
        self.subPropertyID = subPropertyID
        self.experimentName = experimentName
        self.customDimensions = customDimensions
    }

    /// Flattened into Mux's documented key names.
    public var payload: [String: String] {
        var dict: [String: String] = [
            "env_key": environmentKey,
            "player_name": playerName,
            "player_version": playerVersion
        ]
        if let viewerUserID { dict["viewer_user_id"] = viewerUserID }
        if let subPropertyID { dict["sub_property_id"] = subPropertyID }
        if let experimentName { dict["experiment_name"] = experimentName }
        for (index, key) in customDimensions.keys.sorted().enumerated() where index < 5 {
            dict["custom_\(index + 1)"] = customDimensions[key]
        }
        return dict
    }
}

/// Per-view video metadata (`MUXSDKCustomerVideoData`).
public struct HMMuxVideoData: Sendable {
    /// App playlist ID sent as the Mux video ID.
    public var videoID: String
    /// Optional title sent to Mux.
    public var videoTitle: String?
    /// Optional series from item metadata.
    public var videoSeries: String?
    /// Media duration in seconds; mapped to milliseconds in the payload.
    public var videoDuration: TimeInterval?
    /// Mux stream type; player playlists use on-demand.
    public var videoStreamType: String
    /// Playable URL string, empty for an unresolved reference.
    public var videoSourceURL: String
    /// Optional media origin host.
    public var videoCDN: String?
    /// Optional variant from item metadata.
    public var videoVariantName: String?

    /// Flattened Mux schema fields.
    public var payload: [String: String] {
        var dict: [String: String] = [
            "video_id": videoID,
            "video_stream_type": videoStreamType,
            "video_source_url": videoSourceURL
        ]
        if let videoTitle { dict["video_title"] = videoTitle }
        if let videoSeries { dict["video_series"] = videoSeries }
        if let videoDuration { dict["video_duration"] = String(Int(videoDuration * 1000)) }
        if let videoCDN { dict["video_cdn"] = videoCDN }
        if let videoVariantName { dict["video_variant_name"] = videoVariantName }
        return dict
    }

    /// Creates Mux configuration, video metadata or a bounded logging bridge.
    public init(item: HMMediaItem, duration: TimeInterval?) {
        videoID = item.id
        videoTitle = item.title
        videoSeries = item.metadata["series"]
        videoDuration = duration ?? item.durationHint
        videoStreamType = "on-demand"
        videoSourceURL = item.url?.absoluteString ?? ""
        videoCDN = item.url?.host
        videoVariantName = item.metadata["variant"]
    }
}

/// The seam between HotMicPlayer and the real `mux-stats-sdk-avplayer`.
///
/// The SDK ships with a logging implementation so the sample app runs with zero
/// third-party dependencies. Dropping in the real Mux SDK means implementing
/// these four calls — see `Integrations/Mux/MuxDataBridge.swift.txt`.
@MainActor
public protocol HMMuxBridge: AnyObject {
    #if canImport(AVFoundation)
    /// Maps to `MUXSDKStats.monitorAVPlayerLayer(_:withPlayerName:playerData:videoData:)`.
    func monitor(playerLayer: AVPlayerLayer, playerName: String, environment: HMMuxEnvironment, video: HMMuxVideoData)
    #endif
    /// Maps to `MUXSDKStats.videoChangeForPlayer(name:withVideoData:)`.
    func videoChange(playerName: String, video: HMMuxVideoData)
    /// Maps to `MUXSDKStats.destroyPlayer(_:)`.
    func destroy(playerName: String)
    /// Maps to `MUXSDKStats.dispatchError(_:withMessage:forPlayer:)`.
    func dispatchError(playerName: String, code: String, message: String)
}

/// Default bridge: forwards everything to a callback instead of Mux's servers.
/// Used by the sample app to render the exact beacons Mux would receive.
@MainActor
public final class HMLoggingMuxBridge: HMMuxBridge {

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
