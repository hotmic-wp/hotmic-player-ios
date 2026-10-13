# Partner integration guide

Ship a mixed portrait and landscape video feed with your own data, ads and navigation.

## Choose your path

| Path | Pick it when | Copyable starter |
| --- | --- | --- |
| Ready-made overlay | You want metadata, Fire/Comment/Share, previews, captions and an interactive comment sheet immediately. Link HotMicPlayer and HotMicPlayerUI. | [ReadyMadeOverlay](https://github.com/hotmic-wp/hotmic-player-ios/tree/main/Examples/ReadyMadeOverlay) |
| Custom overlay | Your design team owns every rail, metadata view and sheet. Link only HotMicPlayer and compose on the public hooks. | [CustomOverlay](https://github.com/hotmic-wp/hotmic-player-ios/tree/main/Examples/CustomOverlay) |

Both paths share playback, caching, captions, fullscreen and engagement. You can start with ours and replace pieces using `.actionRail`, `.metadata` and `.commentSheet`; the kit retains shared Fire actions and the sheet/squeeze shell. Backend choice is independent of UI choice. Read <doc:IntegrationChecklist> before release and <doc:CapabilityMatrix> to map requirements to APIs.

## Install

Repository URL: `https://github.com/hotmic-wp/hotmic-player-ios`. **1.1.0 is a draft, not a release tag.** Until it is tagged, pin the commit SHA HotMic provides (including measured defaults and subsequent playback/transport fixes) using SwiftPM's revision requirement. Replace `COMMIT_SHA` with that full 40-character SHA and keep that pin in source control for reproducible CI builds:

```swift
.package(url: "https://github.com/hotmic-wp/hotmic-player-ios", revision: "COMMIT_SHA")
```

The latest published alpha, `1.1.0-alpha.2`, contains the ready-made social overlay along with core layout, ads, captions and engagement APIs. It predates the measured defaults and later playback/transport fixes in this unreleased source revision. To evaluate that published baseline, pin:

```swift
.package(url: "https://github.com/hotmic-wp/hotmic-player-ios", exact: "1.1.0-alpha.2")
```

After the stable delivery is published, use that repository URL with `from: "1.1.0"`; do not select an unpublished version in Xcode. Link products using the SwiftPM identity:

```swift
.product(name: "HotMicPlayer", package: "hotmic-player-ios"),
.product(name: "HotMicPlayerUI", package: "hotmic-player-ios") // ready-made path only
```

HotMic engagement is an optional separate package at `https://github.com/hotmic-wp/hotmic-player-connect-ios`. Follow that package's README for its compatible published version and authentication setup; it is not required for your backend or URL playback.

## Twenty-minute quickstart

1. **Minutes 0–5:** open either starter project, select its scheme and run on iOS 17+. No account is needed. Replace the public sample URLs with your MP4 and HLS VOD URLs.
2. **Minutes 5–10:** retain one player per screen lifetime; load stable, unique item IDs and aspect hints. Portrait fills and landscape fits by default.
3. **Minutes 10–15:** connect sharing/comments in the ready-made starter, or style the custom rail and sheet. Reserve navigation and control bounds with the hooks below.
4. **Minutes 15–20:** toggle CC, swipe, pause, open comments and fullscreen, then try the fake pre-rolls in the Sample's Partner demo. Run the checklist before attaching production services.

```swift
import SwiftUI
import HotMicPlayer

@MainActor final class FeedOwner: ObservableObject {
    let player = HMPlayer()
    // Terminal cleanup when the screen owner is released, including source and event subscriptions.
    deinit { MainActor.assumeIsolated { player.teardown() } }
}

@MainActor struct QuickstartFeed: View {
    let mp4URL: URL, hlsURL: URL
    @StateObject private var owner = FeedOwner()
    private var player: HMPlayer { owner.player }
    var body: some View {
        HMVerticalFeedView(player: player)
            .task {
                guard player.items.isEmpty else { return }
                player.replaceAll([
                    .init(id: "portrait", url: mp4URL, format: .mp4, aspectRatio: 9.0 / 16),
                    .init(id: "landscape", url: hlsURL, format: .hls, aspectRatio: 16.0 / 9)
                ])
            }
            .onAppear { player.isFeedVisible = true }
            .onDisappear { if !player.isFullscreen { player.isFeedVisible = false } }
    }
}
```

The surface starts playback automatically. Visibility changes (tabs, navigation pushes) pause/resume the retained player through `isFeedVisible`. `teardown()` is terminal: call it from the owning controller’s permanent dismissal or a main-actor owner’s deinitializer, and create a fresh player for a new lifetime. All player/source/UI access is on the main actor. See <doc:GettingStarted> for lifecycle and events.

## Playlist and ranked-feed refresh

Use stable IDs from your catalog. Five atomic edits cover explicit playlist changes; `reconcile` accepts a complete ranked response while preserving current playback and played history. Empty ranked responses are no-ops. Check the returned Boolean and `loadError` for rejected edits.

```swift
player.replaceAll(items)
player.append(nextPage)
player.insertNext([sponsor])
player.replaceUpcoming(upcoming)
player.remove(ids: removedIDs)
player.reconcile(rankedItems)
```

Use `HMPlaylistSource` for paging and `HMItemResolver` for opaque references. <doc:PlaylistManagement> describes refresh/removal policies, retries and `lastPlaylistChange`.

## Presentation, horizontal and fullscreen

```swift
var configuration = HMPlayerConfiguration.default
configuration.presentation = .automatic
configuration.followsDeviceRotation = true // opt-in; host must allow landscape
let player = HMPlayer(configuration: configuration)
player.enterFullscreen()
player.exitFullscreen()
```

Use `HMPlayerView` for non-paging inline playback or `HMPlayerViewController` for UIKit. Fullscreen reuses the native layer; it has independent zero-inset layout and disables feed paging. Configure supported orientations in the host, including any app delegate override. <doc:HorizontalVideo> covers explicit fit/fill/backdrop policies.

## Layout insets and squeezeback

Insets affect the video, so separately position host chrome. Feed rectangles use full-page coordinates including safe-area space. Measure your nav and sheet; avoid adding the bottom safe area twice.

```swift
HMVerticalFeedView(player: player)
    .hmVideoLayout(HMVideoLayout(contentInsets: HMVideoInsets(bottom: navHeight),
        squeezeTarget: sheetHeight > 0 ? CGRect(x: 0, y: safeTop, width: fullSize.width,
            height: max(0, fullSize.height - navHeight - sheetHeight - safeTop)) : nil))
```

Update `squeezeTarget` on each sheet drag; it resizes the existing video without replacing or seeking. The kit does this and accounts for software keyboard obstruction. See <doc:BuildingYourOwnOverlay> for animation, safe-area, UIKit and free-region placement contracts.

## Gestures and Fire

```swift
HMVerticalFeedView(player: player)
    .hmVideoGestures(isAdPlaying: player.adState.isActive,
        onTap: { player.togglePlayPause() }, onDoubleTap: { point in fire(at: point) })
```

Wrap the actual bounds of controls in `HMHitArea`, or apply `hmExcludedHitArea()` after their padding. Use `hmExcludedHitAreas` for sibling UIKit controls. Do not reserve a full-screen stack containing spacers. Tap toggles playback by default; double tap is opt-in and should **add** Fire, while a rail tap toggles membership. The kit shares one Fire event/animation between both inputs. Native gestures and accessibility actions are suppressed during ads.

## Ready-made overlay or custom UI

```swift
var options = HMSocialOptions()
options.hostNavigationHeight = 54 // excludes system safe area
options.showsMute = true
var callbacks = HMSocialCallbacks()
callbacks.share = { item in presentShare(item) }
callbacks.commentPosted = { item, text in commentSaved(item, text) }
callbacks.sheetChanged = { item, opened in commentsChanged(item, opened) }
let screen = HMSocialPlayerView(player: player, options: options, callbacks: callbacks) { item in socialData(item) }
```

Retain an observable `HMSocialDataSource` per item. A cached `HMEngagementSocialAdapter` must also match the current engagement identity: the player can evict and rebuild engagements. Resolve `let engagement = player.engagement(for: item)` and reuse a cached adapter only when `adapter.engagement === engagement`; otherwise replace it. The kit activates timed replay only for the visible current adapter; custom consumers keep a stable UUID per view instance and call `setReplayActive(true, for: token)` while visible and `setReplayActive(false, for: token)` when hidden. Use `HMSocialModel` for direct host data, or `HMEngagementSocialAdapter` for a source implementing `HMInteractionSource`. Share presentation and backend requests belong to the host. [Ready-made overlay details](https://github.com/hotmic-wp/hotmic-player-ios/blob/main/Sources/HotMicPlayerUI/HotMicPlayerUI.docc/ReadyMadeSocialOverlay.md) cover theming, slots and UIKit embedding.

For custom UI, use `snapshot.state`, `snapshot.videoFrame`, `hmVideoLayout`, `hmVideoGestures`, hit areas, `hmReservedRegions`, `HMOverlayRegions.isFree`, `squeezeTarget`, `adState`, captions and `HMCountFormatter`. The custom starter has its own SwiftUI rail, metadata and comment sheet and imports no kit components. Observe progress in a small leaf view; avoid rebuilding all chrome from every playhead tick. At accessibility text sizes, the kit condenses resting metadata and opens full details separately; its ephemeral preview is omitted to keep controls reachable without competing with vertical paging.

## Ads: your SDK or a URL

Assign a provider before loading items. A decision runs once per item **visit**, including return swipes. `.none` means no fill. See <doc:Ads> for the complete adapter recipe and host responsibilities.

```swift
@MainActor final class URLPreRolls: HMAdBreakProvider {
    let url: URL
    init(url: URL) { self.url = url }
    func adBreak(for item: HMMediaItem) async throws -> HMAdBreak {
        .preRoll(.init(id: "creative", url: url, format: .mp4, aspectRatio: 16.0 / 9))
    }
}
```

The SDK plays URL pre-rolls with aspect fit and a temporary ad engine. For an ad SDK, return `.hostPlayed`: request ads, mount SDK UI in the provided `context.container`, respect playback permission, publish progress and report complete/fail/skip. Stop and release on every terminal outcome. The host owns consent, targeting, tracking, skip eligibility and companion UI. Hide comment entry points whenever `adState.isActive`, including loading, and close an open sheet. The kit does so automatically.

```swift
var configuration = HMPlayerConfiguration.default
configuration.adDecisionTimeout = 1
configuration.adLoadTimeout = 5
configuration.adNoProgressTimeout = 10
configuration.adBreakMaxDuration = 120
let player = HMPlayer(configuration: configuration)
let adActive = player.adState.isActive
let adProgress = player.adProgress
player.skipAd() // host must enforce skip eligibility
```

Timeouts fail open to content. The no-progress watchdog pauses while playback is disallowed; the maximum wall-time cap does not. Swipe-away cancels the break by default. Sidecars remain ordinary host overlays, placed only inside free reserved regions.

## Captions

```swift
let item = HMMediaItem(id: "captioned", url: mp4URL, captionSources: ["en": englishVTT])
player.replaceAll([item])
player.captionsEnabled = true
player.selectCaption("en")
player.captionPreference = nil // return to system Closed Captions + SDH
```

Show CC only when tracks are available. HLS uses AVFoundation legible tracks; MP4 supports WebVTT sidecars. Reserve metadata, rails and nav for safe cues. <doc:Captions> documents preferences, limits and fallback.

## Audio, interruptions and background

```swift
var configuration = HMPlayerConfiguration.default
configuration.managesAudioSession = false // host configures/activates AVAudioSession
configuration.allowsBackgroundAudio = false
let player = HMPlayer(configuration: configuration)
player.isMuted = false
player.isFeedVisible = true
```

Default managed audio is `.playback` / `.moviePlayback`, audio on, without mixing. The player observes interruptions, output-route removal, background/foreground and media resets even when the host owns its session. Background audio is opt-in and also needs the host's Audio background mode; feed visibility is independent of app activation. <doc:AudioAndInterruptions> explains resume intent and forwarded events.

## Accessibility

```swift
HMVerticalFeedView(player: player)
    .hmVideoGestures(accessibilityLabel: "Match highlight")
```

The native video exposes playback state, time, mute/CC and Play/Pause/Fire actions; the kit adds labeled buttons and counts. Custom controls need labels, values, 44-point targets and contrast. Test the largest accessibility text sizes and software keyboard, VoiceOver, Reduce Motion, fullscreen and ads. Do not put a vertical scroll view over a paging feed to fix overflowing chrome. See <doc:Accessibility>.

## Engagement from your backend or Connect

```swift
let engagement = player.engagement(for: item)
try await engagement.setReaction("🔥", reacted: true) // double-tap adds only
try await engagement.toggleReaction("🔥") // rail toggles
try await engagement.loadComments()
try await engagement.sendChat("Great play")
let count = HMCountFormatter().string(from: engagement.commentCount ?? 0)
```

Your backend implements `HMInteractionSource`, advertises `.toggleReaction` / `.loadComments` explicitly and returns authoritative membership/counts and stable paged comment IDs. Catch failures in host controls and preserve drafts. The [custom backend example](https://github.com/hotmic-wp/hotmic-player-ios/tree/main/Examples/CustomEngagementBackend) includes fake transport, optimistic actions and paging.

Connect supplies `HotMicItemResolver`, `HotMicPlaylistSource` and `HotMicInteractionSource` in a separate package. **Per-stream reactions and paged comment history are not yet available from the HotMic backend through Connect.** A host backend can provide the full feature set. The demo's fake Connect source illustrates the adapter boundary and simulates capabilities beyond those currently available from HotMic; it is not a backend availability promise. See <doc:EngagementFromYourBackendOrHotMic>.

## Analytics hooks

```swift
@MainActor final class HostAnalytics: HMAnalyticsSink {
    let sinkName = "host"
    func handle(_ event: HMPlaybackEvent, item: HMMediaItem) {
        // Enqueue into your nonblocking telemetry transport.
        print(item.id, event.kind)
    }
}
```

Add a sink with `player.analytics.add(HostAnalytics())`. Consume `player.events` separately for behavior; each subscriber buffers the newest 256 ordered events. Subscribe before the mutation when its first event matters. Ad state/progress is separate from content impressions. No tracking backend is installed by this package.

## Performance: configure, encode and measure

```swift
var configuration = HMPlayerConfiguration.default
configuration.prefetch = HMPrefetchPolicy(ahead: 3, behind: 1, bytesPerItem: 8 * 1024 * 1024, secondsPerItem: 4)
configuration.maxPrefetchConcurrency = 1
configuration.cacheCapacityBytes = 128 * 1024 * 1024
let player = HMPlayer(configuration: configuration)
```

Start with fixed defaults; adaptive prefetch is explicit opt-in within host budgets. Known final targets activate at lift, while unknown targets wait for settle. See <doc:PrefetchAndPerformance> for independent next preparation, shared downloads and byte limits. Keep current/next media preparation ahead of speculative work and observe `prefetchPlan` when diagnosing decisions. Follow <doc:EncodingForFastStart>: fast-start MP4, aligned HLS segments and byte-range capable immutable hosting matter more than increasing the window blindly.

Use the [performance interpretation guide](https://github.com/hotmic-wp/hotmic-player-ios/blob/main/docs/BENCHMARKING.md): compare owned fixtures under matched workload, cache and network conditions. Use the [public regression harness](https://github.com/hotmic-wp/hotmic-player-ios/blob/main/Sample/TestSupportTools/README.md) to reproduce SDK behavior without a private checkout. Inspect first-frame, stalls, bytes and memory together. Simulator runs prove behavior; performance conclusions require comparable device workloads. Keep raw logs/results out of shipped docs. <doc:IntegrationChecklist> lists what to include in a report.

## Walk through the Partner demo

Open `Sample/HotMicPlayerDemo.xcodeproj`. Add `--hm-partner-demo 1` to launch arguments. The **Feed** tab retains bottom navigation; **Guide** provides the capability walkthrough. In **Demo options**, switch ready-made/custom overlays, fake host/Connect source, mute, captions and replacement slots. Jump to portrait, landscape, URL pre-roll and host SDK break; refresh the ranking; open comments and type with the software keyboard. Source switching constructs a new player lifetime. The demo is credential-free, uses generated MP4 and optionally a host-supplied HLS fixture URL (`--hm-partner-hls-url URL`). Without that argument its HLS entry uses a public sample stream and requires network; local MP4 and fake ads/engagement remain available offline.

The images below render in DocC. On GitHub, open the [ready-made image](Resources/partner-ready.png) or [custom image](Resources/partner-custom.png).

![Ready-made overlay with host navigation](partner-ready.png)
![Custom overlay on core hooks](partner-custom.png)

## Troubleshooting and FAQ

| Symptom / question | Check |
| --- | --- |
| Black video or stalled first frame | URL reachable from simulator/device, correct format, valid VOD, byte ranges, CDN encoding; inspect `loadError` and `.error` events. Explicitly `jump(toID:)` to retry a remembered failed item. |
| Landscape clipped | Remove explicit `.fill`/legacy gravity override, supply aspect hint and allow automatic/fit presentation. |
| Fullscreen remains portrait | Host orientation keys and delegate must allow landscape. Portrait-only expansion is supported. |
| Taps hit video underneath chrome | Reserve actual padded control bounds with `HMHitArea`/`hmExcludedHitArea`; verify surface coordinates after rotation. |
| Comments overlap video/keyboard | Use the kit shell or update the custom squeeze target and keyboard obstruction together. Test with hardware keyboard disabled. |
| No Fire count or older comments via Connect | Backend limitations above; do not advertise unsupported source capabilities. Unknown counts should remain unknown. |
| Caption missing | Wait for track discovery, check language/cue time/file size and free reserved space; reset preference to nil to follow system. |
| Can we use our ad SDK/comments service? | Yes, independently of either overlay path. SDK ads use `.hostPlayed`; social data can be direct or adapted. |
| Can we replace only the rail or sheet? | Yes; use the ready-made replacement slots and retain shared action contexts. |
| Hidden screen still plays | Set `isFeedVisible = false` when hidden without removal; teardown when its lifetime ends. |
| CPU rises while playing | Isolate playhead rendering, avoid work in body, and compare the benchmark with/without host chrome under identical conditions. |
