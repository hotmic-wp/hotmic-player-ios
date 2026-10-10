# HotMicPlayer 1.0 release candidate

A dependency-free Swift package for embedding a vertical MP4 and HLS VOD feed in your app. `HMPlayer` owns playback, five atomic playlist operations, bounded adaptive prefetch and events. Add only the integration layers you need.

| Integration level | Products | Start here |
| --- | --- | --- |
| URLs → your feed UI | `HotMicPlayer` | [PlayerOnly Example](Examples/PlayerOnly), [getting started](Sources/HotMicPlayer/HotMicPlayer.docc/GettingStarted.md) |
| Player + engagement overlay + your data | `HotMicPlayer`, `HotMicPlayerUI` | [PlayerWithUI Example](Examples/PlayerWithUI), [UI guide](Sources/HotMicPlayerUI/HotMicPlayerUI.docc/GettingStarted.md) |
| HotMic content + engagement | Above plus separate `HotMicPlayerConnect` | [HotMicPlayerConnect package](https://github.com/hotmic-wp/hotmic-player-connect-ios) |

## Install

In Xcode, add `https://github.com/hotmic-wp/hotmic-player-ios` as a Package Dependency. Link **HotMicPlayer**, and optionally **HotMicPlayerUI**, to your app target. For a Swift package:

```swift
.package(url: "https://github.com/hotmic-wp/hotmic-player-ios", exact: "1.0.0-rc.4")
```

This branch is `1.0.0-rc.4`. The requirement above resolves after its tag is published. Use `from: "1.0.0"` for the final stable release once that tag is published.

Use the SwiftPM identity `hotmic-player-ios` in your target dependencies:

```swift
.product(name: "HotMicPlayer", package: "hotmic-player-ios"),
.product(name: "HotMicPlayerUI", package: "hotmic-player-ios") // Optional UI
```

## 1. Player only

Given your `mp4URL` and `hlsURL`, keep a player in screen state and present the feed on the main actor:

```swift
import SwiftUI
import HotMicPlayer
@MainActor struct Feed: View {
    @State private var player = HMPlayer()
    let mp4URL: URL, hlsURL: URL
    var body: some View {
        HMVerticalFeedView(player: player)
            .task { player.replaceAll([.init(id: "mp4", url: mp4URL), .init(id: "hls", url: hlsURL)]) }
            .onDisappear { player.teardown() }
    }
}
```

| Playlist operation | Result |
| --- | --- |
| `replaceAll(_:startAt:)` | Selects a new playlist/index; empty becomes idle. |
| `replaceUpcoming(_:)` | Replaces entries after current, preserving playback. |
| `insertNext(_:)` | Inserts immediately after current. |
| `append(_:)` | Adds at the end without interrupting playback. |
| `remove(ids:)` | Removes IDs; removing current selects next survivor, then previous. |

Operations run atomically on the main actor and return `Bool`; invalid edits emit an error and leave the playlist intact. IDs must be nonempty and unique. Use `play`, `pause`, `seek(to:)`, `next`, `previous`, `jump(toID:)` and `isMuted` for controls. Observe `snapshot` and consume `player.events` in a task; each subscription buffers the newest 256 ordered events. Subscribe before editing when the first event matters. `teardown()` is terminal; make a new player for a new screen lifetime.

Paging and opaque content IDs use `HMPlaylistSource` and `HMItemResolver`. See [playlist management](Sources/HotMicPlayer/HotMicPlayer.docc/PlaylistManagement.md) and [event/lifecycle contracts](docs/INTEGRATION.md).

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
import HotMicPlayerConnect
@MainActor func hotMicFeed(resolver: HotMicItemResolver,
                          source: HotMicPlaylistSource,
                          interactions: HotMicInteractionSource) -> some View {
    let player = HMPlayer(resolver: resolver, interactions: interactions)
    player.playlistSource = source
    return HMVerticalFeedView(player: player, layout: HMOverlayLayout.self)
}
```

Retain and tear down the player with the screen as in level 1. The adapter package owns the HotMicCore integration; this package has no Core dependency. This candidate supports VOD. See the [integration boundary](Sources/HotMicPlayer/HotMicPlayer.docc/HotMicIntegration.md).

## Requirements and performance

- Xcode 16+ / Swift 6 package tools. The package currently compiles in Swift 5 language mode.
- iOS 17+ for the player and UI. The player/feed also compile for tvOS 17+. HotMicPlayerUI is iOS-only. macOS 14+ supports platform-independent models and tests.
- Immutable public HTTP(S) or file VOD URLs. Live, DRM, authenticated-origin renewal and advanced HLS coverage are outside this release's supported contract.

Start with `HMPlayerConfiguration.default`, `.instantStart` or `.highQuality`. Defaults remain two players, a 128 MB disk cap and adaptive prefetch within app budgets. Tune window, prefix bytes/seconds, cache cap, concurrency, resolution horizon and startup bitrate using [prefetch and performance](Sources/HotMicPlayer/HotMicPlayer.docc/PrefetchAndPerformance.md). Set `managesAudioSession: false` when your host owns the audio session.

Read the [benchmark guide](docs/BENCHMARKING.md) before drawing performance conclusions. Compare TTFF, stalls, bytes and memory on identical physical-device workloads; simulator smoke runs demonstrate correctness. `prefetchPlan` exposes the last applied plan and reason. Experimental thresholds, strategies and JSONL tooling require Benchmark SPI and are outside the partner contract.

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
