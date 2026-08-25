import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Environment-level Mux Data configuration (`MUXSDKCustomerPlayerData`).
public struct HMMuxEnvironment: Sendable {
    public var environmentKey: String
    public var playerName: String
    public var playerVersion: String
    public var viewerUserID: String?
    public var subPropertyID: String?
    public var experimentName: String?
    /// `custom_1` ... `custom_5` in the Mux schema.
    public var customDimensions: [String: String]

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
    public var videoID: String
    public var videoTitle: String?
    public var videoSeries: String?
    public var videoDuration: TimeInterval?
    public var videoStreamType: String
    public var videoSourceURL: String
    public var videoCDN: String?
    public var videoVariantName: String?

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

    public init(item: HMMediaItem, duration: TimeInterval?) {
        videoID = item.id
        videoTitle = item.title
        videoSeries = item.metadata["series"]
        videoDuration = duration ?? item.durationHint
        videoStreamType = item.streamKind == .live ? "live" : "on-demand"
        videoSourceURL = item.url.absoluteString
        videoCDN = item.url.host
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

    public struct Beacon: Identifiable, Sendable {
        public let id = UUID()
        public let call: String
        public let playerName: String
        public let payload: [String: String]
        public let timestamp = Date()
    }

    public private(set) var beacons: [Beacon] = []
    public var onBeacon: ((Beacon) -> Void)?
    private let capacity: Int

    public init(capacity: Int = 100) { self.capacity = capacity }

    private func record(_ call: String, _ playerName: String, _ payload: [String: String]) {
        let beacon = Beacon(call: call, playerName: playerName, payload: payload)
        beacons.insert(beacon, at: 0)
        if beacons.count > capacity { beacons.removeLast(beacons.count - capacity) }
        onBeacon?(beacon)
    }

    #if canImport(AVFoundation)
    public func monitor(playerLayer: AVPlayerLayer, playerName: String, environment: HMMuxEnvironment, video: HMMuxVideoData) {
        record("monitorAVPlayerLayer", playerName, environment.payload.merging(video.payload) { _, new in new })
    }
    #endif

    public func videoChange(playerName: String, video: HMMuxVideoData) {
        record("videoChangeForPlayer", playerName, video.payload)
    }

    public func destroy(playerName: String) {
        record("destroyPlayer", playerName, [:])
    }

    public func dispatchError(playerName: String, code: String, message: String) {
        record("dispatchError", playerName, ["player_error_code": code, "player_error_message": message])
    }
}
