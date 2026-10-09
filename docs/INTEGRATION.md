# Integrating HotMicPlayer 0.3.0

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

IDs are app-chosen, nonempty and unique within the playlist. Duplicate edits are rejected as a whole and emit `.error(item:kind:)`. Items carry an explicit source, optional poster/title/author/duration hint and `[String: String]` metadata. `.auto` uses the extension, then HTTP content type for extensionless URLs (HEAD, with a GET of bytes 0–1 if HEAD fails); supplying `.mp4` or `.hls` avoids that detection request. Ergonomic `.url(url, poster: poster, id: "clip")` and `.reference("partner", id: "external", playlistID: "clip")` constructors are available. Without an explicit playlist ID the URL constructor uses its absolute URL and the reference constructor uses namespace plus reference ID.

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

Use `player.isFeedVisible = false` when the host disappears or backgrounds. Setting it true resumes a resolved current item synchronously; an unresolved entry must first finish resolution. `pause()` records playback intent so hiding and showing a paused player keeps it paused. Call `teardown()` on permanent dismissal; it ends this player instance. The default player configures and activates `AVAudioSession` for playback, and deactivates it on teardown. If your app owns the session, set `managesAudioSession: false` before creating/presenting the player. With that flag false, playback, foreground resume and teardown leave your session category and activation alone. `startsMuted` sets the initial mute state; `loops` controls repeating at the end of a VOD. All three are stable public settings:

```swift
let configuration = HMPlayerConfiguration(loops: false, startsMuted: true, managesAudioSession: false)
let player = HMPlayer(configuration: configuration)
// The host configures and activates its own AVAudioSession when appropriate.
```

## Atomic editing and navigation

All five operations are synchronous `@MainActor` methods returning `Bool` (discardable). They validate the entire resulting list before committing. An empty replacement is valid only with `startAt: 0`; an out-of-range start is rejected. Upcoming/insert/append on an empty playlist start it at the first incoming entry. Removal ignores unknown IDs. Removing current selects the first surviving entry after its old position, or the last surviving entry before it; removing everything becomes idle.

```swift
player.replaceUpcoming(newTail)
player.insertNext(promotions)
player.append(page)
player.remove(ids: ["expired"])
player.replaceAll(newPlaylist, startAt: 2)
```

During a swipe, the current entry means the last settled page. Swipes commit by stable item ID. Appends preserve an in-progress drag or animation. Other edits preserve it when both current and destination IDs remain at the same positions; otherwise the bridge cancels the move and anchors to current (or its selected survivor). Edits to an unrelated tail therefore preserve the swipe. Empty append/insert and removal of unknown IDs emit no event and do not change revision. No surviving current item is reattached, activated, sought, or paused by an edit. New next media replaces a displaced warm assignment, subject to current-buffer gating.

`next()` and `previous()` do nothing at the ends. `jump(toID:)` reports an error for unknown IDs. `seek(to:)` takes seconds, rejects negative/non-finite values, and clamps to the known duration. `isMuted` applies to current and prepared players. `play()` and `pause()` preserve position. `seek(toProgress:)` and toggle helpers support overlays. Animated `requestPage(at:)` and async `requestPlay(at:requestedAt:)` are Benchmark SPI.

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

Assign `player.playlistSource`, then `await player.start()`. Pages drop already-loaded IDs and within-page repetitions, emit the non-fatal `.sourcePageDuplicates(ids:)` event, and append new entries through the usual prefetch path. The cursor advances even on an all-duplicate page. Partner-called operations still reject duplicates atomically. Paging triggers when three entries remain after current (the low-water tuning is Benchmark SPI). A nil next cursor ends the source; a repeated cursor ends automatic paging to prevent a request loop. Append, insert, upcoming replacement and removal preserve an in-flight source request and cursor; the returned page merges against the latest list. A successful `replaceAll` resets the source cursor to nil, restores source availability and clears the retry budget. A page already in flight finishes without cancellation, but its old-cursor result is ignored; subsequent paging starts from nil. An invalid `replaceAll` leaves the cursor intact. Assigning a new source resets the cursor and cancels the old request.

Thrown source errors and rejected pages each emit one `.error` event and update `loadError` per failed attempt. Near the end, paging allows four total attempts, waiting 1, 2 and 4 seconds between them. After the fourth failure it stops automatic requests while `hasMoreContent` stays true. Moving to another current item or explicitly calling `loadNextPage()` resets the budget; repeated `start()` calls and unrelated playlist edits do not. Explicit loads during an existing fetch do nothing. Successful pages clear the error and retry budget. `HMStaticPlaylistSource` supports samples/tests, finite lists and looping lists with distinct IDs.

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

Resolution covers current plus the configured data/warm window, independently of buffer gating for media downloads. Concurrent requests for one immutable entry are coalesced, completed results persist for the player session, and pending work is cancelled on leaving the window, hiding or teardown. Resolver implementations should cooperate with cancellation. Late results cannot activate removed entries. Transient failures retry up to three automatic attempts with 1/2/4-second capped backoff; becoming current resets the budget. Pending work is promoted to user-initiated priority when its item becomes current or next, without a second resolver call. Already-resolved entries activate synchronously. Playlist metadata overrides resolved hints. A missing resolver produces `.missingResolver`; it never constructs a fake playback URL. The future Core adapter will use namespace `hotmic` in a separate package.

## Optional engagement

Implement `@MainActor HMInteractionSource` and pass it to init. `timeline(for:)` returns an `HMStreamTimeline` without opening a session. Lifecycle hooks manage only current and next: `willBecomeNext`, `didBecomeCurrent`, `didLeave`. Promotion keeps the next session open; entries that leave both roles, disappear or tear down receive `didLeave`. Optional async `sendChat`, `react`, and `vote` default to throwing `.unsupportedAction`. The host retains its adapter and invokes these actions from its overlay. The default implementation supplies deterministic demo timelines without network sessions.

## Events and analytics

```swift
.task {
    for await event in player.events {
        // currentItemChanged, itemReady, firstFrame(ttff:readiness:),
        // stallStarted, stallEnded, error, playlistChanged, nearingEnd, sourcePageDuplicates
        handle(event)
    }
}
```

Each access to `events` creates an independent ordered subscription, buffering the newest 256 events; slow consumers can lose older events. Cancelling the consuming task releases that subscription. Observation clients can read `items`, `activeIndex`, `currentItem`, `snapshot`, paging state, `loadError` and `lastEvent`. Snapshots expose getters with internal setters; activation/frame flags are Benchmark SPI diagnostics. Subscribe before mutation when the first edit matters. TTFF is seconds in `HMPlayerEvent`; analytics `ttff_ms` remains milliseconds. Readiness (`cold`, `cachedBytes`, `warmPlayer`) is measured at activation, not retroactively after decoding.

Create an `HMAnalyticsHub`, register sinks and pass `analytics:` to init. Existing `HMAnalyticsSink`, `HMConsoleSink` and `HMMuxAnalyticsSink` contracts remain. JSONL, mock timelines and the logging Mux bridge are Benchmark SPI. The real Mux bridge belongs to the host; see [Mux integration](../Integrations/Mux/README.md). `finishRun()` and transfer/prefetch-error/startup-summary/run-end telemetry are Benchmark SPI. `HMPlaybackEvent.Kind.rawValue` remains a stable string for sinks; the kind has no public `CaseIterable` or `RawRepresentable` conformance. Decoding recorded categories requires Benchmark SPI.

## Transport settings and limits

The default preset has two native players, a 128 MB disk cap and a fixed data window. Media prefetch waits for a safe current buffer. Resolution does not wait for that gate. The loopback listener publishes its port only after ATS/health verification; failure falls back to direct URLs. A dead listener is re-armed on next use or foreground, and each restart repeats the health check before publishing its port. Current requests use high priority and speculative requests have a separate low-priority session. Stream inactivity times out after 20 seconds of permitted upstream work; intentional full-buffer backpressure pauses that clock. HLS playlists are memory-only with configurable `configuration.playlistTTL` (default 30 seconds).

Use versioned VOD paths. Query parameters are preserved in cache identity; volatile signing-parameter tuning is Benchmark SPI. Shared known resources survive removal of another owner and the LRU remains a hard cap. Live, DRM, authenticated origins, signed-playlist renewal, HLS byte-range/alternate-audio coverage and concurrent active players sharing the same disk directory remain outside the supported contract. Playback UI is iOS/tvOS; macOS package tests exercise platform-independent logic.

## Stable configuration

Start from `.default`, `.instantStart` or `.highQuality`. The supported tuning surface is `poolSize` (1–4), `prefetch.ahead`/`behind` (0–8), `prefetch.bytesPerItem` (up to 8 MiB), optional `prefetch.secondsPerItem`, `cacheCapacityBytes`, `startupPeakBitRate` (bits/s, zero unrestricted), `playlistTTL` (memory-only, seconds), `loops`, `startsMuted` and `managesAudioSession`. `HMPrefetchPolicy` also supplies `off`, `nextOnly`, `balanced` and `aggressive` window presets. For example:

```swift
var configuration = HMPlayerConfiguration.instantStart
configuration.prefetch = HMPrefetchPolicy(ahead: 2, behind: 1, bytesPerItem: 800_000, secondsPerItem: 3)
configuration.cacheCapacityBytes = 64_000_000
let player = HMPlayer(configuration: configuration)
```

All other engine tuning, S0–S3 names, configuration serialization (`benchmarkRecord` is Codable)/fingerprint, cache reset and benchmark entry points require `@_spi(Benchmark) import HotMicPlayer`. SPI is experimental and is excluded from [the compiled partner API inventory](PUBLIC_API.md).


Measured adaptive prefetch is enabled by default. The app's prefetch budgets
remain maxima; `HMPlayerConfiguration(adaptive: false)` selects fixed settings.
See [adaptive prefetch](ADAPTIVE_PREFETCH.md) for the replaceable public policy,
readiness tiers, thresholds and telemetry. No network-type rules are applied.
