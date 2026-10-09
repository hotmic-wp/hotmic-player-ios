# Public API inventory — 0.2.0

Extracted from the compiled iOS simulator module. This lists all explicitly exported types, functions, initializers, properties and enum cases, including the unchanged analytics/timeline contracts. Synthesized protocol conformances are omitted. Compiler accessor spellings may include restricted setters; consult the source declaration for setter access. Actor isolation and behavioral contracts are documented in source and [Integration](INTEGRATION.md).

## HMAnalyticsHub

```swift
@MainActor func add(_ sink: any HMAnalyticsSink)
@MainActor init(sinks: [any HMAnalyticsSink] = [])
@MainActor func remove(named name: String)
@MainActor var sinks: [any HMAnalyticsSink] { get }
```

## HMAnalyticsSink

```swift
@MainActor func attach(playerLayer: AVPlayerLayer, playerKey: String, item: HMMediaItem)
@MainActor func detach(playerKey: String)
@MainActor func handle(_ event: HMPlaybackEvent, item: HMMediaItem)
@MainActor var sinkName: String { get }
@MainActor func videoChange(playerKey: String, item: HMMediaItem)
```

## HMConsoleSink

```swift
@MainActor func clear()
@MainActor var entries: [HMConsoleSink.Entry] { get set }
@MainActor func handle(_ event: HMPlaybackEvent, item: HMMediaItem)
@MainActor init(capacity: Int = 250, mirrorsToOSLog: Bool = true)
@MainActor let sinkName: String
```

## HMConsoleSink.Entry

```swift
let event: HMPlaybackEvent
let id: UUID
let itemTitle: String
var kind: HMPlaybackEvent.Kind { get }
var timestamp: Date { get }
```

## HMDensityBucket

```swift
let dominantEmoji: String?
let eventCount: Int
var id: Int { get }
let index: Int
init(index: Int, position: Double, intensity: Double, dominantEmoji: String?, eventCount: Int)
let intensity: Double
let position: Double
```

## HMInteractionError

```swift
case unsupportedAction
```

## HMInteractionSource

```swift
@MainActor func didBecomeCurrent(_ item: HMMediaItem)
@MainActor func didLeave(_ item: HMMediaItem)
@MainActor func react(_ emoji: String, for item: HMMediaItem) async throws
@MainActor func sendChat(_ text: String, for item: HMMediaItem) async throws
@MainActor func timeline(for item: HMMediaItem) -> any HMStreamTimeline
@MainActor func vote(pollID: String, optionID: String, for item: HMMediaItem) async throws
@MainActor func willBecomeNext(_ item: HMMediaItem)
```

## HMItemResolver

```swift
func resolve(_ ref: HMMediaItem.Reference) async throws -> HMResolvedItem
```

## HMJSONLFileSink

```swift
@MainActor let fileURL: URL
@MainActor func flush() async throws
@MainActor func handle(_ event: HMPlaybackEvent, item: HMMediaItem)
@MainActor init(fileURL: URL, runID: String, configuration: HMPlayerConfiguration, format: String, network: String, script: String, buildSHA: String, dimensions: [String : String] = [:]) throws
@MainActor let sinkName: String
```

## HMLoggingMuxBridge

```swift
@MainActor var beacons: [HMLoggingMuxBridge.Beacon] { get }
@MainActor func destroy(playerName: String)
@MainActor func dispatchError(playerName: String, code: String, message: String)
@MainActor init(capacity: Int = 100)
@MainActor func monitor(playerLayer: AVPlayerLayer, playerName: String, environment: HMMuxEnvironment, video: HMMuxVideoData)
@MainActor var onBeacon: ((HMLoggingMuxBridge.Beacon) -> Void)?
@MainActor func videoChange(playerName: String, video: HMMuxVideoData)
```

## HMLoggingMuxBridge.Beacon

```swift
let call: String
let id: UUID
let payload: [String : String]
let playerName: String
let timestamp: Date
```

## HMMediaItem

```swift
let author: String?
let durationHint: TimeInterval?
var format: HMMediaItem.Format { get }
let id: String
init(id: String, source: HMMediaItem.Source, posterURL: URL? = nil, title: String? = nil, author: String? = nil, durationHint: TimeInterval? = nil, metadata: [String : String] = [:])
init(id: String, url: URL, format: HMMediaItem.Format = .auto, posterURL: URL? = nil, title: String? = nil, author: String? = nil, durationHint: TimeInterval? = nil, metadata: [String : String] = [:])
let metadata: [String : String]
let posterURL: URL?
static func reference(_ namespace: String, id: String, playlistID: String? = nil) -> HMMediaItem
let source: HMMediaItem.Source
let title: String?
var url: URL? { get }
static func url(_ url: URL, poster: URL? = nil, id: String? = nil, format: HMMediaItem.Format = .auto) -> HMMediaItem
```

## HMMediaItem.Format

```swift
case auto
case hls
case mp4
```

## HMMediaItem.Reference

```swift
let id: String
init(namespace: String, id: String)
let namespace: String
```

## HMMediaItem.Source

```swift
case reference(namespace: String, id: String)
case url(URL, format: HMMediaItem.Format = .auto)
```

## HMMockInteractionSource

```swift
@MainActor init()
@MainActor func timeline(for item: HMMediaItem) -> any HMStreamTimeline
```

## HMMockTimeline

```swift
@MainActor func append(_ event: HMTimelineEvent)
@MainActor var density: [HMDensityBucket] { get }
@MainActor let duration: TimeInterval
@MainActor var events: [HMTimelineEvent] { get }
@MainActor func events(in range: ClosedRange<TimeInterval>) -> [HMTimelineEvent]
@MainActor init(itemID: String, duration: TimeInterval, intensity: Double = 1.0)
@MainActor var markers: [HMTimelineMarker] { get }
```

## HMMuxAnalyticsSink

```swift
@MainActor func attach(playerLayer: AVPlayerLayer, playerKey: String, item: HMMediaItem)
@MainActor func detach(playerKey: String)
@MainActor var environment: HMMuxEnvironment
@MainActor func handle(_ event: HMPlaybackEvent, item: HMMediaItem)
@MainActor init(environment: HMMuxEnvironment, bridge: any HMMuxBridge)
@MainActor convenience init(environmentKey: String, viewerUserID: String? = nil)
@MainActor let sinkName: String
@MainActor func videoChange(playerKey: String, item: HMMediaItem)
```

## HMMuxBridge

```swift
@MainActor func destroy(playerName: String)
@MainActor func dispatchError(playerName: String, code: String, message: String)
@MainActor func monitor(playerLayer: AVPlayerLayer, playerName: String, environment: HMMuxEnvironment, video: HMMuxVideoData)
@MainActor func videoChange(playerName: String, video: HMMuxVideoData)
```

## HMMuxEnvironment

```swift
var customDimensions: [String : String]
var environmentKey: String
var experimentName: String?
init(environmentKey: String, playerName: String = "HotMicPlayer", playerVersion: String = HotMicPlayer.version, viewerUserID: String? = nil, subPropertyID: String? = nil, experimentName: String? = nil, customDimensions: [String : String] = [:])
var payload: [String : String] { get }
var playerName: String
var playerVersion: String
var subPropertyID: String?
var viewerUserID: String?
```

## HMMuxVideoData

```swift
init(item: HMMediaItem, duration: TimeInterval?)
var payload: [String : String] { get }
var videoCDN: String?
var videoDuration: TimeInterval?
var videoID: String
var videoSeries: String?
var videoSourceURL: String
var videoStreamType: String
var videoTitle: String?
var videoVariantName: String?
```

## HMPageTransition

```swift
func attributes(offset: Double, height: Double) -> HMPageTransition.Attributes
case cover
case cube
var displayName: String { get }
case fade
var id: String { get }
case none
case parallax
case scale
```

## HMPageTransition.Attributes

```swift
var anchor: UnitPoint
var offsetY: Double
var opacity: Double
var perspective: Double
var rotationDegrees: Double
var scale: Double
```

## HMPlaybackEvent

```swift
var description: String { get }
let id: UUID
init(kind: HMPlaybackEvent.Kind, itemID: String, timestamp: Date = Date(), monotonicTime: TimeInterval = ProcessInfo.processInfo.systemUptime, position: TimeInterval = 0, metrics: [String : Double] = [:], properties: [String : String] = [:])
let itemID: String
let kind: HMPlaybackEvent.Kind
let metrics: [String : Double]
let monotonicTime: TimeInterval
let position: TimeInterval
let properties: [String : String]
let timestamp: Date
```

## HMPlaybackEvent.Kind

```swift
case ended
case error
case firstFrame
case loadStart
case pause
case play
case playerRecycled
case playing
case prefetchError
case preloadReady
case preloadStart
case rebufferEnd
case rebufferStart
case runEnd
case seeked
case seeking
case startupSummary
case transfer
case transportError
case variantChanged
case viewEnd
case viewStart
```

## HMPlaybackSnapshot

```swift
var activationID: String
var bufferedAhead: TimeInterval
var currentTime: TimeInterval
var duration: TimeInterval
var errorDescription: String?
var indicatedBitrate: Double
init()
var isFrameReady: Bool
var isLive: Bool
var isMuted: Bool
var progress: Double { get }
var readinessTier: HMReadinessTier
var seekableDuration: TimeInterval { get }
var seekableStart: TimeInterval
var stallCount: Int
var state: HMPlaybackState
var timeToFirstFrame: TimeInterval?
var totalStallDuration: TimeInterval
var wasPreloaded: Bool
```

## HMPlaybackState

```swift
case buffering
case failed
case idle
case loading
case paused
case playing
case ready
```

## HMPlaybackStrategy

```swift
case S0
case S1
case S2
case S3
var usesDataCache: Bool { get }
```

## HMPlayer

```swift
@MainActor var activeIndex: Int { get }
@MainActor let analytics: HMAnalyticsHub
@discardableResult @MainActor func append(_ items: [HMMediaItem]) -> Bool
@MainActor var configuration: HMPlayerConfiguration { get set }
@MainActor var currentItem: HMMediaItem? { get }
@MainActor var events: AsyncStream<HMPlayerEvent> { get }
@MainActor func finishRun() async
@MainActor var hasMoreContent: Bool { get set }
@MainActor init(configuration: HMPlayerConfiguration = .default, resolver: (any HMItemResolver)? = nil, interactions: (any HMInteractionSource)? = nil, analytics: HMAnalyticsHub? = nil)
@discardableResult @MainActor func insertNext(_ items: [HMMediaItem]) -> Bool
@MainActor var isFeedVisible: Bool { get set }
@MainActor var isLoadingPage: Bool { get set }
@MainActor var isMuted: Bool { get set }
@MainActor var items: [HMMediaItem] { get }
@MainActor func jump(toID id: String)
@MainActor var lastEvent: HMPlayerEvent? { get set }
@MainActor var loadError: String? { get set }
@MainActor func loadNextPage() async
@MainActor func next()
@MainActor func pause()
@MainActor func play()
@MainActor var playlistRevision: Int { get set }
@MainActor var playlistSource: (any HMPlaylistSource)? { get set }
@MainActor var preparedItemCount: Int { get }
@MainActor func previous()
@discardableResult @MainActor func remove(ids: Set<String>) -> Bool
@discardableResult @MainActor func replaceAll(_ items: [HMMediaItem], startAt: Int = 0) -> Bool
@discardableResult @MainActor func replaceUpcoming(_ items: [HMMediaItem]) -> Bool
@MainActor func requestPage(at index: Int)
@MainActor func requestPlay(at index: Int, requestedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) async
@MainActor func seek(to seconds: TimeInterval)
@MainActor func seek(toProgress progress: Double)
@MainActor var snapshot: HMPlaybackSnapshot { get }
@MainActor func snapshot(for item: HMMediaItem) -> HMPlaybackSnapshot
@MainActor func start() async
@MainActor func teardown()
@MainActor func timeline(for item: HMMediaItem) -> any HMStreamTimeline
@MainActor func toggleMute()
@MainActor func togglePlayPause()
```

## HMPlayerCache

```swift
static func reset() async
```

## HMPlayerConfiguration

```swift
var cacheCapacityBytes: Int
static let `default`: HMPlayerConfiguration
var fingerprint: String { get }
static let highQuality: HMPlayerConfiguration
init(strategy: HMPlaybackStrategy = .S3, poolSize: Int = 2, prefetch: HMPrefetchPolicy = HMPrefetchPolicy(), cacheCapacityBytes: Int = 128_000_000, steadyBufferDuration: TimeInterval = 10, startupPeakBitRate: Double = 1_600_000, steadyPeakBitRate: Double = 0, startupBitRateWindow: TimeInterval = 4, loops: Bool = true, startsMuted: Bool = false, managesAudioSession: Bool = true, restoresPlaybackPosition: Bool = true, lowWaterMark: Int = 3, playlistTTL: TimeInterval = 30)
static let instantStart: HMPlayerConfiguration
var loops: Bool
var lowWaterMark: Int
var managesAudioSession: Bool
var playlistTTL: TimeInterval
var poolSize: Int
var prefetch: HMPrefetchPolicy
static func preset(_ strategy: HMPlaybackStrategy) -> HMPlayerConfiguration
var restoresPlaybackPosition: Bool
var startsMuted: Bool
var startupBitRateWindow: TimeInterval
var startupPeakBitRate: Double
var steadyBufferDuration: TimeInterval
var steadyPeakBitRate: Double
var strategy: HMPlaybackStrategy
var volatileSigningQueryParameters: [String]
```

## HMPlayerError

```swift
case duplicateID(String)
var errorDescription: String? { get }
case invalidIndex(Int)
case invalidSeek
case missingResolver
case playback(String)
case playlistSource(String)
case resolution(String)
case unsupportedURL
```

## HMPlayerEvent

```swift
case currentItemChanged(HMMediaItem?)
case error(item: HMMediaItem?, kind: HMPlayerError)
case firstFrame(HMMediaItem, ttff: TimeInterval, readiness: HMReadinessTier)
case itemReady(HMMediaItem)
case nearingEnd(remaining: Int)
case playlistChanged([HMMediaItem])
case stallEnded(HMMediaItem)
case stallStarted(HMMediaItem)
```

## HMPlaylistPage

```swift
init(items: [HMMediaItem], nextCursor: String?)
let items: [HMMediaItem]
let nextCursor: String?
```

## HMPlaylistSource

```swift
func loadPage(cursor: String?) async throws -> HMPlaylistPage
```

## HMPrefetchPolicy

```swift
static let aggressive: HMPrefetchPolicy
var ahead: Int
static let balanced: HMPrefetchPolicy
var behind: Int
var bytesPerItem: Int
init(ahead: Int = 5, behind: Int = 1, warmBufferDuration: TimeInterval = 3, bytesPerItem: Int = 800_000, secondsPerItem: TimeInterval? = nil, startThreshold: TimeInterval = 3)
static let maximumBytesPerItem: Int
static let nextOnly: HMPrefetchPolicy
static let off: HMPrefetchPolicy
var secondsPerItem: TimeInterval?
var startThreshold: TimeInterval
var warmBufferDuration: TimeInterval
```

## HMReadinessTier

```swift
case cachedBytes
case cold
case warmPlayer
```

## HMResolvedItem

```swift
let duration: TimeInterval?
let format: HMMediaItem.Format
init(url: URL, format: HMMediaItem.Format = .auto, poster: URL? = nil, title: String? = nil, duration: TimeInterval? = nil)
let poster: URL?
let title: String?
let url: URL
```

## HMStaticPlaylistSource

```swift
init(items: [HMMediaItem], pageSize: Int = 6, loopsForever: Bool = true, simulatedLatency: Duration = .milliseconds(350))
let items: [HMMediaItem]
func loadPage(cursor: String?) async throws -> HMPlaylistPage
let loopsForever: Bool
let pageSize: Int
let simulatedLatency: Duration
```

## HMStreamTimeline

```swift
@MainActor func append(_ event: HMTimelineEvent)
@MainActor var density: [HMDensityBucket] { get }
@MainActor var duration: TimeInterval { get }
@MainActor func events(in range: ClosedRange<TimeInterval>) -> [HMTimelineEvent]
@MainActor var markers: [HMTimelineMarker] { get }
```

## HMTimelineEvent

```swift
let author: String?
let emoji: String?
let id: String
init(id: String = UUID().uuidString, offset: TimeInterval, kind: HMTimelineEvent.Kind, author: String? = nil, text: String? = nil, emoji: String? = nil, magnitude: Int = 1)
let kind: HMTimelineEvent.Kind
let magnitude: Int
let offset: TimeInterval
let text: String?
```

## HMTimelineEvent.Kind

```swift
case chat
case marker
case poll
case question
case reaction
case tip
case vote
```

## HMTimelineMarker

```swift
let count: Int
let emoji: String
let id: String
init(id: String, offset: TimeInterval, position: Double, emoji: String, count: Int, label: String? = nil)
let label: String?
let offset: TimeInterval
let position: Double
```

## HMVerticalFeedView

```swift
@MainActor var body: some View { get }
@MainActor init(player: HMPlayer, transition: HMPageTransition = .none, gravity: AVLayerVideoGravity = .resizeAspectFill)
@MainActor init(player: HMPlayer, transition: HMPageTransition = .none, gravity: AVLayerVideoGravity = .resizeAspectFill, @ViewBuilder overlay: @escaping (HMMediaItem, HMPlaybackSnapshot) -> Overlay)
```

## HotMicPlayer

```swift
static let version: String
```

## EnvironmentValues.hmFeedSafeArea

```swift
var hmFeedSafeArea: EdgeInsets { get set }
```
