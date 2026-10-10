# ``HotMicPlayer``

Embed a vertical MP4 and HLS VOD feed, with your own interface or the optional HotMicPlayerUI product.

## Overview

Create an ``HMPlayer`` on the main actor, give it uniquely identified ``HMMediaItem`` values, and present ``HMVerticalFeedView``. The player owns playback, atomic playlist edits, bounded prefetch, and ordered events. It has no third-party dependencies and requires no HotMic account for URL playback.

Use iOS 17 or later and Xcode 16 or later (Swift 6 tools). Playback and the feed also compile for tvOS 17; HotMicPlayerUI is iOS-only. macOS 14 supports the platform-independent models and unit suite, not the feed engine.

Choose an integration level:

1. **Player only:** supply VOD URLs and render your own overlay. Start with <doc:GettingStarted>.
2. **Player + UI:** add the HotMicPlayerUI product and your `HMInteractionSource`. See the [UI guide](https://github.com/hotmic-wp/hotmic-player-ios/tree/main/Sources/HotMicPlayerUI/HotMicPlayerUI.docc).
3. **HotMic streams + engagement:** add the separate HotMicPlayerConnect adapter package. See <doc:HotMicIntegration>.

All player, timeline, source, and engagement access is isolated to the main actor. Resolver and paging protocols are `Sendable` and can perform asynchronous work outside that actor. Exported value models can cross tasks. Benchmark SPI and internal engine objects are outside the semver contract.

## Topics

### Integration guides
- <doc:GettingStarted>
- <doc:HorizontalVideo>
- <doc:HotMicIntegration>
- <doc:PlaylistManagement>
- <doc:PrefetchAndPerformance>
- <doc:EncodingForFastStart>
- <doc:EngagementAndCustomSources>

### Playback and playlists
- ``HMPlayer``
- ``HMVerticalFeedView``
- ``HMPlayerView``
- ``HMPlayerViewController``
- ``HMVideoPresentation``
- ``HMVideoBackdropColor``
- ``HMMediaItem``
- ``HMPlayerConfiguration``
- ``HMPlaybackSnapshot``
- ``HMPlaybackState``
- ``HMPageTransition``
- ``HMPlayerEvent``
- ``HMPlayerError``
- ``HMFailedItemPolicy``
- ``HMPlaylistSource``
- ``HMPlaylistPage``
- ``HMStaticPlaylistSource``
- ``HMItemResolver``
- ``HMResolvedItem``

### Prefetch policy
- ``HMPrefetchPolicy``
- ``HMPrefetchPolicyProviding``
- ``HMAdaptivePrefetchPolicy``
- ``HMPrefetchInputs``
- ``HMPrefetchPlan``
- ``HMReadinessTier``

### Engagement data and actions
- ``HMEngagement``
- ``HMInteractionSource``
- ``HMInteractionError``
- ``HMEngagementCapabilities``
- ``HMEngagementError``
- ``HMChatMessage``
- ``HMPoll``
- ``HMReactionEcho``
- ``HMStreamTimeline``
- ``HMTimelineEvent``
- ``HMDensityBucket``
- ``HMTimelineMarker``

### Analytics
- ``HMAnalyticsHub``
- ``HMAnalyticsSink``
- ``HMConsoleSink``
- ``HMPlaybackEvent``
- ``HMMuxAnalyticsSink``
- ``HMMuxBridge``
- ``HMMuxEnvironment``
- ``HMMuxVideoData``

### Version
- ``HotMicPlayer``

### Host-built overlays

- <doc:BuildingYourOwnOverlay>
