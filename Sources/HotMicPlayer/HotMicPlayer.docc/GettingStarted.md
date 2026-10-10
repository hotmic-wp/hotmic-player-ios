# Getting started: player only

Turn MP4 and HLS VOD URLs into a vertical feed.

## Install

Add `https://github.com/hotmic-wp/hotmic-player-ios` in Xcode's Package Dependencies, then link the **HotMicPlayer** product to your app target. In a package manifest:

```swift
.package(url: "https://github.com/hotmic-wp/hotmic-player-ios", exact: "1.1.0-alpha.1")
```

`1.1.0-alpha.1` is the published core API baseline. The ready-made overlay requires the reviewed commit revision until the next stable tag; see <doc:PartnerIntegrationGuide> for the draft delivery and version policy.

Use the SwiftPM identity `hotmic-player-ios` in your target dependencies:

```swift
.product(name: "HotMicPlayer", package: "hotmic-player-ios"),
.product(name: "HotMicPlayerUI", package: "hotmic-player-ios") // Optional UI
```

## Present a feed

Keep one player in SwiftUI state for the screen's lifetime. Replace `mp4URL` and `hlsURL` with your immutable, public HTTP(S) VOD URLs. File URLs also work.

```swift
import SwiftUI
import HotMicPlayer

@MainActor struct FeedScreen: View {
    let mp4URL: URL
    let hlsURL: URL
    @State private var player = HMPlayer(configuration: .default)
    var body: some View {
        HMVerticalFeedView(player: player) { item, snapshot in
            Text(item.title ?? "Video").foregroundStyle(.white)
        }
        .task {
            guard player.items.isEmpty else { return }
            player.replaceAll([
                HMMediaItem(id: "intro", url: mp4URL, format: .mp4),
                HMMediaItem(id: "replay", url: hlsURL, format: .hls)
            ])
        }
        .onAppear { player.isFeedVisible = true }
        .onDisappear { player.isFeedVisible = false }
    }
}
```

The feed calls ``HMPlayer/start()`` automatically. Use `play()`, `pause()`, `next()`, `previous()`, `jump(toID:)`, `seek(to:)` and `isMuted` for host controls. `currentIndex` is nil while idle; `activeIndex` retains its compatibility value of zero. Treat `teardown()` as terminal; create a new player when presenting a new screen after teardown.

The feed pauses while backgrounded or hidden. A host that hides the feed without removing it should set `isFeedVisible`. If your app owns `AVAudioSession`, create the player with `HMPlayerConfiguration(managesAudioSession: false)`.

## Subscribe to events

Read `snapshot` from SwiftUI for rendering. Consume `events` in a task for behavior:

```swift
.task {
    let events = player.events
    for await event in events {
        if case .error(_, let kind) = event { print(kind.localizedDescription) }
    }
}
```

Each access creates a separate subscription with the newest 256 events buffered. Subscribe before a playlist edit if that edit's notification matters. SwiftUI cancels a view task automatically; cancel an independently owned consuming task yourself. Ordered delivery is per subscriber, and slow consumers can lose old events. `lastEvent` exposes only the latest notification.

## Configure and extend

Start with `.default`, `.instantStart` or `.highQuality`; see <doc:PrefetchAndPerformance>. Invalid playlist edits return false and emit an error; network failures are reported through events rather than thrown by transport controls. Source and resolver calls use `async throws`; engagement actions rethrow failures after restoring optimistic state.

For paging implement ``HMPlaylistSource``. For opaque identifiers use `.reference(namespace:id:)` items and an ``HMItemResolver``. See <doc:PlaylistManagement>. A player without an interaction source has empty, read-only engagement.

Open the [PlayerOnly Example](https://github.com/hotmic-wp/hotmic-player-ios/tree/main/Examples/PlayerOnly) for a complete 40-line app with all five operations. It links only public API and requires no backend.

## Handle future enum cases

Minor releases may add cases to non-frozen public enums such as `HMPlayerEvent` and `HMPlaybackState`. Use `@unknown default` in client switches to provide a fallback for future cases:

```swift
switch player.snapshot.state {
case .playing: showPlaying()
case .idle, .loading, .ready, .paused, .buffering, .failed: showOtherState()
@unknown default: showOtherState()
}
```
