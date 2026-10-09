# Integrating HotMicPlayer 0.2.0

The SDK is a source Swift package with no third-party dependencies, for iOS 17+. Playback supports immutable VOD MP4 and HLS; hosts supply their catalogue, overlays and optional adapters.

## Step 1 — create a player and supply entries

```swift
@State private var player = HMPlayer(configuration: .default)

// Run on the main actor (use await when calling from another actor).
player.replaceAll([
    HMMediaItem(id: "clip-a", source: .url(mp4URL, format: .mp4), title: "Intro"),
    HMMediaItem(id: "clip-b", source: .url(hlsURL, format: .hls), title: "Replay")
])
```

IDs are app-chosen, nonempty and unique within the playlist. Duplicate edits are rejected as a whole and emit `.error(item:kind:)`. Items carry an explicit source, optional poster/title/author/duration hint and `[String: String]` metadata. `.auto` uses the extension, then HTTP content type for extensionless URLs; supplying `.mp4` or `.hls` avoids that detection request. Ergonomic `.url(url, poster: poster, id: "clip")` and `.reference("partner", id: "external", playlistID: "clip")` constructors are available. Without an explicit playlist ID the URL constructor uses its absolute URL and the reference constructor uses namespace plus reference ID.

## Step 2 — render video with your overlay

```swift
struct FeedScreen: View {
    @State private var player = HMPlayer()

    var body: some View {
        HMVerticalFeedView(player: player) { item, snapshot in
            HouseOverlay(item: item, snapshot: snapshot)
        }
        .task {
            player.playlistSource = ClipPlaylist()
            await player.start()
        }
    }
}
```

[MinimalIntegration.swift](../Sample/HotMicPlayerDemo/Integration/MinimalIntegration.swift) compiles this shape in the Sample app with only `import HotMicPlayer`. The overlay gets the item (including resolved metadata fallbacks) and an observable snapshot with state, position, duration, buffer, bitrate, stalls, TTFF and readiness tier. Use `snapshot.currentTime` to query `player.timeline(for: item)`; overlays render from the media clock, so seeking rewinds engagement along with video.

Use `player.isFeedVisible = false` when the host disappears or backgrounds. Setting it true resumes a resolved current item synchronously; an unresolved entry must first finish resolution. `pause()` records playback intent so hiding and showing a paused player keeps it paused. Call `teardown()` on permanent dismissal; it ends this player instance. Hosts that manage their own audio session should set `configuration.managesAudioSession = false`.

## Atomic editing and navigation

All five operations are synchronous `@MainActor` methods returning `Bool` (discardable). They validate the entire resulting list before committing. An empty replacement is valid only with `startAt: 0`; an out-of-range start is rejected. Upcoming/insert/append on an empty playlist start it at the first incoming entry. Removal ignores unknown IDs. Removing current selects the first surviving entry after its old position, or the last surviving entry before it; removing everything becomes idle.

```swift
player.replaceUpcoming(newTail)
player.insertNext(promotions)
player.append(page)
player.remove(ids: ["expired"])
player.replaceAll(newPlaylist, startAt: 2)
```

During a swipe, the current entry means the last settled page. An accepted edit cancels the pending scroll destination and snaps back to that current item's new position. If current was removed, it snaps to the selected survivor. Old scroll commits are invalidated by playlist revision. No surviving current item is reattached, activated, sought, or paused by an edit. New next media replaces a displaced warm assignment, subject to current-buffer gating.

`next()` and `previous()` do nothing at the ends. `jump(toID:)` reports an error for unknown IDs. `seek(to:)` takes seconds, rejects negative/non-finite values, and clamps to the known duration. `isMuted` applies to current and prepared players. `play()` and `pause()` preserve position. `seek(toProgress:)`, toggle helpers, animated `requestPage(at:)` and async `requestPlay(at:requestedAt:)` support overlay and benchmark integrations.

## Optional paging

```swift
struct ClipPlaylist: HMPlaylistSource {
    func loadPage(cursor: String?) async throws -> HMPlaylistPage {
        let page = try await ClipsAPI.clips(after: cursor)
        return HMPlaylistPage(items: page.clips.map {
            HMMediaItem(id: $0.id, url: $0.hlsURL, posterURL: $0.posterURL, title: $0.headline)
        }, nextCursor: page.nextCursor)
    }
}
```

Assign `player.playlistSource`, then `await player.start()`. Pages append through the same duplicate-validation and prefetch path as `append`. `configuration.lowWaterMark` (default 3) triggers fetching when that many entries remain after current. A nil next cursor ends the source. Source replacement or `replaceAll` invalidates pending pages and resets the cursor. Tail edits invalidate pending pages while retaining the last committed cursor. Manual `loadNextPage()` can retry a paging failure. `HMStaticPlaylistSource` supports samples/tests, finite lists and looping lists with distinct IDs.

## Optional reference resolution

```swift
struct CatalogueResolver: HMItemResolver {
    func resolve(_ ref: HMMediaItem.Reference) async throws -> HMResolvedItem {
        let clip = try await Catalogue.lookup(namespace: ref.namespace, id: ref.id)
        return HMResolvedItem(url: clip.url, format: .hls, title: clip.title)
    }
}
let player = HMPlayer(resolver: CatalogueResolver())
player.replaceAll([.reference("partner", id: "episode-7")])
```

Resolution covers current plus the configured data/warm window, independently of buffer gating for media downloads. Concurrent requests for one immutable entry are coalesced, completed results persist for the player session, and pending work is cancelled on leaving the window, hiding or teardown. Resolver implementations should cooperate with cancellation. Late results cannot activate removed entries. Already-resolved entries activate synchronously. Playlist metadata overrides resolved hints. A missing resolver produces `.missingResolver`; it never constructs a fake playback URL. The future Core adapter will use namespace `hotmic` in a separate package.

## Optional engagement

Implement `@MainActor HMInteractionSource` and pass it to init. `timeline(for:)` returns an `HMStreamTimeline` without opening a session. Lifecycle hooks manage only current and next: `willBecomeNext`, `didBecomeCurrent`, `didLeave`. Promotion keeps the next session open; entries that leave both roles, disappear or tear down receive `didLeave`. Optional async `sendChat`, `react`, and `vote` default to throwing `.unsupportedAction`. The host retains its adapter and invokes these actions from its overlay. The default `HMMockInteractionSource` supplies deterministic demo timelines without network sessions.

## Events and analytics

```swift
.task {
    for await event in player.events {
        // currentItemChanged, itemReady, firstFrame(ttff:readiness:),
        // stallStarted, stallEnded, error, playlistChanged, nearingEnd
        handle(event)
    }
}
```

Each access to `events` creates an independent ordered subscription, buffering the newest 256 events; slow consumers can lose older events. Cancelling the consuming task releases that subscription. Observation clients can read `items`, `activeIndex`, `currentItem`, `snapshot`, paging state, `loadError`, `lastEvent` and `preparedItemCount`. Subscribe before mutation when the first edit matters. TTFF is seconds in `HMPlayerEvent`; analytics `ttff_ms` remains milliseconds. Readiness (`cold`, `cachedBytes`, `warmPlayer`) is measured at activation, not retroactively after decoding.

Create an `HMAnalyticsHub`, register sinks and pass `analytics:` to init. Existing `HMAnalyticsSink`, `HMConsoleSink`, `HMJSONLFileSink`, and `HMMuxAnalyticsSink` contracts remain. The real Mux bridge belongs to the host; see [Mux integration](../Integrations/Mux/README.md). `finishRun()` drains transport metrics and emits runEnd for benchmark runs, after which the player is terminal.

## Transport settings and limits

Default S3 has two native players, a 128 MB disk cap and a fixed data window. Media prefetch waits for a safe current buffer. Resolution does not wait for that gate. The loopback listener publishes its port only after ATS/health verification; failure falls back to direct URLs. Current requests use high priority and speculative requests have a separate low-priority session. Stream inactivity times out after 20 seconds of permitted upstream work; intentional full-buffer backpressure pauses that clock. HLS playlists are memory-only with configurable `configuration.playlistTTL` (default 30 seconds).

Use versioned VOD paths. Signing query parameters are stripped from cache identity only when explicitly named in `volatileSigningQueryParameters`. Shared known resources survive removal of another owner and the LRU remains a hard cap. Live, DRM, authenticated origins, signed-playlist renewal, HLS byte-range/alternate-audio coverage and concurrent active players sharing the same disk directory remain outside the supported contract. Playback UI is iOS/tvOS; macOS package tests exercise platform-independent logic.
