# HotMicPlayer

A dependency-free Swift package for embedding a vertical MP4 and HLS VOD feed in your app. `HMPlayer` owns playback, atomic playlist operations, fixed bounded prefetch with adaptive opt-in and events. Add only the integration layers you need.

| Integration level | Products | Start here |
| --- | --- | --- |
| URLs → your feed UI | `HotMicPlayer` | [PlayerOnly Example](Examples/PlayerOnly), [getting started](Sources/HotMicPlayer/HotMicPlayer.docc/GettingStarted.md) |
| Player + engagement overlay + your data | `HotMicPlayer`, `HotMicPlayerUI` | [PlayerWithUI Example](Examples/PlayerWithUI), [UI guide](Sources/HotMicPlayerUI/HotMicPlayerUI.docc/GettingStarted.md) |
| HotMic content + engagement | Above plus separate `HotMicPlayerConnect` | [HotMicPlayerConnect package](https://github.com/hotmic-wp/hotmic-player-connect-ios) |

See [Engagement from your backend or HotMic](Sources/HotMicPlayer/HotMicPlayer.docc/EngagementFromYourBackendOrHotMic.md) and the [custom backend adapter](Examples/CustomEngagementBackend) for host-built comments and fire UI.

Start with the [Partner integration guide](Sources/HotMicPlayer/HotMicPlayer.docc/PartnerIntegrationGuide.md), [capability matrix](Sources/HotMicPlayer/HotMicPlayer.docc/CapabilityMatrix.md) and [integration checklist](Sources/HotMicPlayer/HotMicPlayer.docc/IntegrationChecklist.md). Choose either [ReadyMadeOverlay](Examples/ReadyMadeOverlay) or [CustomOverlay](Examples/CustomOverlay); both starters build in examples CI. The 1.1.0 changelog is a draft.

## Install

For the latest features, pin the commit SHA HotMic provides from this repository in SwiftPM as described in the [integration guide](Sources/HotMicPlayer/HotMicPlayer.docc/PartnerIntegrationGuide.md). The ready-made social overlay is not yet tagged. Link **HotMicPlayer**, and optionally **HotMicPlayerUI**, to your app target. For the published core API baseline only:

```swift
.package(url: "https://github.com/hotmic-wp/hotmic-player-ios", exact: "1.1.0-alpha.1")
```

`1.1.0-alpha.1` contains core layout, ads, captions and engagement, but does not include the ready-made overlay. Pin the commit SHA HotMic provides for that path and subsequent fixes, following the integration guide. Use the repository URL above with `from: "1.1.0"` only after the stable tag is published.

Use the SwiftPM identity `hotmic-player-ios` in your target dependencies:

```swift
.product(name: "HotMicPlayer", package: "hotmic-player-ios"),
.product(name: "HotMicPlayerUI", package: "hotmic-player-ios") // Optional UI
```

## 1. Player only

Given your real HLS and MP4 URLs, keep one player owner in screen state and present the feed on the main actor:

```swift
import SwiftUI
import HotMicPlayer
@MainActor final class FeedOwner: ObservableObject {
    let player = HMPlayer()
    // Terminal cleanup when the screen owner is released, including source and event subscriptions.
    deinit { MainActor.assumeIsolated { player.teardown() } }
}

@MainActor struct Feed: View {
    @StateObject private var owner = FeedOwner()
    private var player: HMPlayer { owner.player }
    let mp4URL: URL, hlsURL: URL
    var body: some View {
        HMVerticalFeedView(player: player)
            .task { guard player.items.isEmpty else { return }; player.replaceAll([.init(id: "hls", url: hlsURL, format: .hls), .init(id: "mp4", url: mp4URL, format: .mp4)]) }
            .onAppear { player.isFeedVisible = true }
            .onDisappear { player.isFeedVisible = false }
    }
}
```

| Playlist operation | Result |
| --- | --- |
| `replaceAll(_:startAt:)` | Selects a new playlist/index; empty becomes idle. |
| `reconcile(_:)` | Refreshes ranking around current, preserving history; empty is a no-op. |
| `replaceUpcoming(_:)` | Replaces entries after current, preserving playback. |
| `insertNext(_:)` | Inserts immediately after current. |
| `append(_:)` | Adds at the end without interrupting playback. |
| `remove(ids:)` | Removes IDs; removing current selects next survivor, then previous. |

Operations run atomically on the main actor and return `Bool`; invalid edits emit an error and leave the playlist intact. IDs must be nonempty and unique. Use `play`, `pause`, `seek(to:)`, `next`, `previous`, `jump(toID:)` and `isMuted` for controls. Observe `snapshot` and consume `player.events` in a task; each subscription buffers the newest 256 ordered events. Subscribe before editing when the first event matters. `teardown()` is terminal; make a new player for a new screen lifetime.

Paging and opaque content IDs use `HMPlaylistSource` and `HMItemResolver`. See [playlist management](Sources/HotMicPlayer/HotMicPlayer.docc/PlaylistManagement.md) and [event/lifecycle contracts](docs/INTEGRATION.md).

## Horizontal video and inline playback

The feed now defaults to `.automatic`: matching vertical media fills, while landscape clips and pre-rolls fit without cropping. Supply `HMMediaItem(aspectRatio: 16.0 / 9.0)` as a first-paint hint; decoded track/presentation size takes precedence. Select `.fill`, `.fit`, `.fitWithBlurredBackdrop` or `.fitWithColor` through `configuration.presentation` or an item override. Overlay snapshots expose `videoFrame` in page coordinates.

Use `HMPlayerView(player:)` for a non-paging 16:9 inline player, or embed `HMPlayerViewController(player:)` in UIKit and constrain its view. Both share the feed engine, cache and playlist controls. Call `enterFullscreen()` / `exitFullscreen()` and observe `isFullscreen`; fullscreen moves the same video layer and disables feed swipes. Opt into landscape device rotation with `configuration.followsDeviceRotation = true`. Landscape fullscreen requires the host app to allow landscape orientations; portrait-only apps safely expand fullscreen in portrait. Overlay closures also render fullscreen. Inline players pause when removed and resume on appearance unless explicitly paused.

See [Horizontal video](Sources/HotMicPlayer/HotMicPlayer.docc/HorizontalVideo.md) for policies, UIKit integration and host orientation setup, and [the Sample](Sample/HotMicPlayerDemo/App/HorizontalLabScreen.swift) for a mixed feed and inline example.

## 2. Player + UI + your interaction source

`MemorySource` below is your `HMInteractionSource`; [the compiled Example](Examples/PlayerWithUI/PlayerWithUI/MemorySource.swift) includes a complete in-memory implementation with chat, reactions and a poll.

```swift
import SwiftUI
import HotMicPlayer
import HotMicPlayerUI
@MainActor func partnerFeed(items: [HMMediaItem]) -> some View {
    let player = HMPlayer(interactions: MemorySource())
    var theme = HMTheme.default
    theme.colors.accent = .orange
    player.replaceAll(items)
    return HMVerticalFeedView(player: player, layout: HMOverlayLayout.self).hmTheme(theme)
}
```

For a real screen, retain the player in state and tear it down as in level 1. Use `HMOverlayLayout.Options` and `.hmOverlayOptions(_:)` to choose regions, chat limits, insets and Share handling. Compose individual UI components or implement `HMEngagementLayout` for your own arrangement. See [theming](Sources/HotMicPlayerUI/HotMicPlayerUI.docc/Theming.md) and [custom sources](Sources/HotMicPlayer/HotMicPlayer.docc/EngagementAndCustomSources.md).

Without a source, engagement is empty and read-only. Sources declare supported actions, own current/next sessions, and supply media-clock timelines. Player-created engagements borrow the source weakly; sources must hold engagements weakly. Send confirmed server IDs to deduplicate echoes. Authoritative `updateReactions` counts survive engagement eviction; count-removal deltas are instance-local. Moderation deletions survive for the item's playlist lifetime, with overflow diagnostics in unified logs.

## 3. HotMic content + engagement

Install [HotMicPlayerConnect](https://github.com/hotmic-wp/hotmic-player-connect-ios) separately and follow its README to construct its adapters. Its `HotMicItemResolver`, `HotMicPlaylistSource` and `HotMicInteractionSource` implement the player’s public plug-in protocols:

```swift
import SwiftUI
import HotMicPlayer
import HotMicPlayerUI
@MainActor func hotMicFeed(resolver: any HMItemResolver,
                          source: any HMPlaylistSource,
                          interactions: any HMInteractionSource) -> some View {
    let player = HMPlayer(resolver: resolver, interactions: interactions)
    player.playlistSource = source
    return HMVerticalFeedView(player: player, layout: HMOverlayLayout.self)
}
```

Retain the player with the screen as in level 1; hide it with `isFeedVisible` and call terminal `teardown()` only when its owner is permanently dismissed. The adapter package owns the HotMicCore integration; this package has no Core dependency. This candidate supports VOD. See the [integration boundary](Sources/HotMicPlayer/HotMicPlayer.docc/HotMicIntegration.md).

## Requirements and performance

- Xcode 16+ / Swift 6 package tools. The package currently compiles in Swift 5 language mode.
- iOS 17+ for the player and UI. The player/feed also compile for tvOS 17+. HotMicPlayerUI is iOS-only. macOS 14+ supports platform-independent models and tests.
- Immutable public HTTP(S) or file VOD URLs. Live, DRM, authenticated-origin renewal and advanced HLS coverage are outside this release's supported contract.

The defaults and new APIs below describe this unreleased source revision. Existing alpha tags retain their published behavior; pin the reviewed public commit supplied by HotMic for these changes. `.default`, `HMPlayerConfiguration()` and `HMPlayer()` use the same settings:

| Setting | Default and units |
| --- | --- |
| Feed examples | Real HLS VOD URLs marked `.hls`; MP4 remains supported |
| Startup network preference | 1,600,000 bits/s for the existing 4-second startup window |
| Native content players | 2: current and immediate next |
| Data window | Fixed 3 ahead / 1 behind; adaptive off |
| Per-entry preparation | Target 4 media seconds; hard payload cap 8 × 1024 × 1024 bytes (8 MiB) |
| Disk cache | 128,000,000 bytes globally, including pinned entries |
| Explicit prefix concurrency | One bounded transfer at a time |
| Metadata horizon | Up to 8 following entries by default; no additional players |
| Activation | Finger lift when the final aligned target ID is known; settled fallback otherwise |

```swift
import HotMicPlayer
let player = HMPlayer()
let hls = URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!
player.replaceAll([HMMediaItem(id: "match-1", url: hls, format: .hls)])
```

Format belongs to the item/resolver. There is no global MP4-to-HLS converter. Connect currently passes its backend's `vodURL` with `.auto`; changing the backend/adapter contract is a separate integration step. `startupPeakBitRate` is AVPlayer's desired bandwidth preference, not an exact rendition or network-rate guarantee. Its 4-second startup window and the 4-second prefix target are independent settings.

```text
retained bytes       current decoder       next decoder        bounded data only
     N-1                  N                    N+1                N+2   N+3
                          |                     |
                      request priority      one admitted head
                          +---- metadata resolution farther ahead ----+
```

On a committed page change, the prepared next node becomes current once. The outgoing node is recycled for the new immediate next; the previous entry retains useful in-window bytes without a decoder. Window edits diff surviving identities, trim removed routes/work, and preserve shared resources and the globally bounded disk cache. Identical and metadata-only refreshes preserve the clock, layer, assignments and in-flight work. Reorders reprioritize surviving work instead of rebuilding the playlist; demoted preparation retains its useful bytes and in-window transfer.

Fixed mode starts upcoming preparation independently of the current first frame and unknown dwell. Current requests lead, then immediate next, then farther forward prefixes. A true rebuffer after playback began holds speculative progress until recovery. Temporary pressure parks surviving tasks between bounded chunks; a new immediate next can take the next slot. A current read or admitted prefix can preempt a warm native socket holding that same resource, retaining received bytes; explicit joins remain chunk-bounded. Native and explicit prefix reads coalesce in either direction and consume cached bytes. Warm-native and explicit speculative payload share the per-entry cap; activated playback has its own native buffering demands.

HLS preparation parses CR/LF playlists and quoted attributes, chooses a rendition heuristic under the startup preference, includes default alternate audio and init/key dependencies, and selects complete segments (including byte ranges). AVPlayer can choose another rendition. The planner checks whole resource sizes before admission, accounts manifests/audio/video together, and reports an unattainable duration target. HEAD rejection (403/405/501) or unknown length falls back to bounded, budgeted GET metadata probes and reuses fetched bytes. Manifests are bounded to 512 KiB and the remaining entry budget. Unsupported speculative ranges or an insufficient budget can still yield no prefix; native activation remains available. An oversized Range-less origin switches activated playback to AVPlayer’s direct origin transport on the same node and activation; this fallback does not provide proxy byte accounting or reuse for the remaining direct reads. Immutable VOD/master playlists stay in memory while retained; live/EVENT playlists use the configured TTL. This is not a live/DRM/authenticated-renewal guarantee.

At lift, the paging bridge reads the final aligned target after forwarding the native paging callback. It never predicts a destination from velocity or a transient scroll position. Unknown targets wait for settle. Cancelled/return-to-origin drags retain current. Gesture telemetry keeps touch, lift, activation, first-frame and settle clocks distinct and records any target/settle mismatch as unsuccessful activation. Fullscreen, resize and playlist-edit guards remain in place; early selection does not write a second scroll animation.

Speculative payload accounting includes loopback manifest/audio/video/init bodies and warm native requests, including revisits that are currently inactive. It excludes HTTP/TLS overhead, resolver format probes, posters and separate sidecar-caption fetches. The budget is not a bound on all network traffic or activated native playback.

First moving playback is observed from positive media-clock progress on existing native ticks and logged separately from first frame and native control status. Explicit seek/loop decode catch-up with already-playable buffered media receives at most 150 ms of grace, followed by a waiting-state recheck; prolonged waits and empty-buffer waits after playback began count as rebuffering. This observation is sampled timing, not a frame-exact moving-pixel detector.

Deliberate alternatives: `.instantStart` requests 900,000 bits/s for 3 startup seconds and an 8-second steady buffer; `.highQuality` leaves startup unrestricted with a 20-second steady buffer. Both retain two players and the fixed data window. `.off` disables upcoming native/media preparation (current playback continues). `.nextOnly`, `.balanced` and `.aggressive` adjust the data window. Set `adaptive = true` explicitly for measured adaptation within app budgets, or `activationTrigger = .settle` to always wait. Use `managesAudioSession: false` when the host owns audio. See [prefetch details](Sources/HotMicPlayer/HotMicPlayer.docc/PrefetchAndPerformance.md).

### Evidence and comparison inventory

These are separate revisions and conditions, not a single before/after benchmark. Simulator checks validate behavior and cannot establish device performance. A grid file on disk is not evidence that it ran.

| Comparison/work | Evidence and status |
| --- | --- |
| Initial S0/S1/S2/S3, MP4/HLS | Historical simulator smoke ran; functional comparison only, no current physical speed claim |
| Loopback transport | Bounded Range/block reads and connection reuse implemented in earlier work; current shared-download checks build on those fixes |
| Adaptive policy | Historical pure-policy/hysteresis checks ran; adaptive remains opt-in; current fixed bootstrap differs from that baseline |
| Physical baseline | October 9, iPhone 14 / iOS 27.0.1 / Xcode 26.6, historical rc.2 source `9b485ab`; shaped Wi-Fi, one repeat per cell; details below |
| Later speed round | Approximately 16 ms swipe result was simulator-only; not comparable to physical results |
| Streaming delivery queue | Serial queued deliveries, first chunk immediate, suspend at 64 KiB plus in-flight delegate chunk and resume at 16 KiB: tried, no gain, reverted |
| One actor entry per chunk | Combined priority gating, socket delivery and cache accounting, avoiding unlimited-chunk copies: tried, no gain, reverted |
| Rewind | Exact zero-tolerance rewind before recycle regressed work; restored native ±infinity tolerances for that rewind, preserving exact normal seeks and frame invalidation |
| Format/player count/window/byte-time budgets | Historical comparisons and supplied observations informed defaults; no matched current device rerun is claimed |
| Fixed versus adaptive, lift versus settle | Author-reported observations below; exact run/build/network hashes unavailable |
| Independent bootstrap/shared downloads | Implemented and exercised with generated HLS on the dedicated simulator; current device comparison pending |
| Refresh/reorder/demotion | Generated-media simulator flow exercised metadata/reorder, two-node demotion, shared-URL insertion, both removal policies and teardown; repeated full reshuffles remain costly |
| Current behavioral acceptance | Native cancelled drags, pause-burst, back, horizontal/fullscreen/rotation, overlays and ads passed; a 6.8 ms rewind false stall was fixed; sampled moving clock is separate from first frame |
| Budget/origin failures | 300,000-byte budget produced complete 2-second prefixes and reported the unattainable 4-second target; HEAD-unavailable activation and offline-origin recovery exercised; oversized Range-less retry was found and fixed with direct fallback |
| iPhone 16 Pro and iPhone 11 matched comparisons | Pending: identical content/network/cache/build, at least three repeats per cell |

The October 9 baseline used a local HTTP/1.1 origin: good approximately 30 Mbps with 50 ms added response latency; poor approximately 1.5 Mbps with 200 ms, no loss. Six clips repeated under stable distinct entry IDs, SDK cache reset per cell, 12 good-link cells plus six poor binge-only cells (poor normal was omitted), with initial plus 20 swipes each: **378 attempted activations, 269 first frames, 109 never-started/censored**. Good-link first video was 454.3–578.9 ms (one observation per cell); S3 swipe medians were approximately 67–117 ms (S0 approximately 434–500 ms). Good-link swipe p90 values were:

| Format/pace | S0 direct | S3 adaptive | S3 fixed |
| --- | ---: | ---: | ---: |
| MP4 binge | 607 ms | 201.5 ms | 270.1 ms |
| MP4 normal | 623.9 ms | 83.1 ms | 83.2 ms |
| HLS binge | 550 ms | 100.1 ms | 116.4 ms |
| HLS normal | 516.6 ms | 116.8 ms | 133.3 ms |

Poor-link S0 MP4 started 17/20 swipes, p90 1,133.8 ms. HLS in all modes and S3 MP4 started **0/21** views in their cells; their medians are unavailable, not zero. Missing starts motivated startup/starvation investigation; those runs alone did not isolate the internal cause. Good-link S0 MP4 recorded 10/14 observed startup-window stalls, S3 MP4 binge one per mode, and the other good cells zero; short dwell truncates the ten-second summaries. Sampled memory was 18.81–25.27 MB, not a continuous peak. Unused-byte accounting means bytes never delivered to activated playback, not proof that a frame was watched. These historical samples do not measure this revision's changes.

Supplied later observations, without matched raw provenance: normal swipe first-frame medians approximately 85 ms on iPhone 16 Pro and 118–135 ms on iPhone 11; slower-link pause-burst fixed 92–119 ms versus adaptive approximately 950 ms; continuous one-second swipes approximately 575–600 ms with downloading the bottleneck. Lift activation reportedly saved approximately 355 ms while iPhone 16 Pro settling increased 38–81 ms. Fixed unused bytes were approximately 1.5–2.3 MB/run versus adaptive 0.2–0.7 MB/run on slower-link normal/pause-burst workloads. Repeated full reshuffles increased waste/stalls. MP4 sometimes showed a frame earlier but moving playback came later and stalls were worse; HLS remains the example default. These are observations, not reproduced results or guarantees; first-frame medians include only started views.

Future comparisons must include attempted/started/never-started coverage; first versus swipe p50/p90; first frame and first moving playback; stall count/time; network and unused bytes; reuse, memory/player counts and settling. Keep lift/settle clocks distinct. See the [benchmark guide](docs/BENCHMARKING.md). `prefetchPlan` exposes the applied plan; detailed JSONL telemetry remains available through Benchmark SPI and the analytics hub.

## Examples and documentation

- [PlayerOnly](Examples/PlayerOnly): 40 lines, MP4 + HLS URLs and all five playlist buttons; public API only.
- [PlayerWithUI](Examples/PlayerWithUI): overlay options, orange/yellow theme and an in-memory interaction source; public API only.
- [Sample](Sample): full demo, playlist/reference labs and benchmark app. Uses Benchmark SPI deliberately. Open `Sample/HotMicPlayerDemo.xcodeproj`.
- [Player DocC catalog](Sources/HotMicPlayer/HotMicPlayer.docc) and [UI DocC catalog](Sources/HotMicPlayerUI/HotMicPlayerUI.docc): build in Xcode with Product → Build Documentation.
- [Encoding and hosting for fast start](Sources/HotMicPlayer/HotMicPlayer.docc/EncodingForFastStart.md): partner MP4/HLS settings and CDN checklist.
- [Public API inventory](docs/PUBLIC_API.md), [1.0 API decisions](docs/API_REVIEW_1.0.md), [changelog](CHANGELOG.md).

## Versioning and support

From 1.0, public non-SPI API follows semantic versioning: patches fix behavior, minors add compatible API, and majors may remove or change contracts. Renames retain deprecated forwarding API with compiler fix-its. New cases may be added to non-frozen public enums in minor releases; use `@unknown default` in client switches. Benchmark SPI, private implementation and demo tooling may change without compatibility guarantees. Pre-release versions carry an explicit suffix and are for evaluation.

Report SDK problems through [repository issues](https://github.com/hotmic-wp/hotmic-player-ios/issues) or your HotMic partner contact. Include SDK/Xcode/iOS versions, a minimal reproduction, expected behavior, and relevant events. Use the Connect package's support channel for adapter-specific issues. Remove credentials and private media URLs from shared reports.

For a host-built social UI, see [Building your own overlay](Sources/HotMicPlayer/HotMicPlayer.docc/BuildingYourOwnOverlay.md): nav insets, interactive squeezeback, gesture exclusions, reserved regions, accessibility and counts. The Sample’s **Social layout** screen uses public SDK API.

## Ready-made social overlay

Add the optional **HotMicPlayerUI** product for `HMSocialPlayerView` (SwiftUI) or `HMSocialPlayerViewController` (UIKit). Supply an observable `HMSocialDataSource` directly from your backend, or adapt `HMEngagement` with `HMEngagementSocialAdapter`. The themeable kit includes metadata/hashtags, ephemeral comment previews, one shared Fire animation, Fire/Comment/Share rail, progress, optional mute and scrubbing, captions and an interactive squeezed comment sheet. Hosts supply persistent navigation, sharing and optional sidecar/replacement sheet content.

See [Ready-made social overlay](Sources/HotMicPlayerUI/HotMicPlayerUI.docc/ReadyMadeSocialOverlay.md) for data, theming, component composition and the behavior mapping. The Sample's **Partner demo** uses fake data and generated mixed-orientation video, with a switch between kit UI and custom UI on public hooks. You can also build your own UI using only HotMicPlayer; both integration paths use the same playback/layout hooks.

Visible paused seeks retain transport permission when lifecycle and audio policy allow it; returning from background or an interruption does not require resuming playback to fetch a seek frame. Hidden or audio-blocked work stays suspended and cancellable.
