# Integrating HotMicPlayer 0.3.1

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

Resolution covers current plus the configured data/warm window, independently of buffer gating for media downloads. Concurrent requests for one immutable entry are coalesced, completed results persist for the player session, and pending work is cancelled on leaving the window or teardown (hiding pauses media work but allows in-flight resolution to finish). Resolver implementations should cooperate with cancellation. Late results cannot activate removed entries. Non-connectivity resolution failures use three total automatic attempts, waiting 1 and 2 seconds between them. Connectivity/timeout errors stay selected and retry without exhausting that terminal budget. Explicit navigation to a failed entry resets its budget; automatic skips and duplicate page-settle callbacks do not. Pending work is promoted to user-initiated priority when its item becomes current or next, without a second resolver call. Already-resolved entries activate synchronously. A current unresolved reference activates and attaches its video surface automatically when its result arrives, including after initial selection, jump, swipe and insert/next. Its snapshot reports `.loading` with readiness `.resolving` until resolution succeeds. TTFF includes resolution and media loading from the selection tap or page commit. Swipes and programmatic pages (including benchmark autopilot) start timing when the page settles/commits, never at gesture start or animation request. Duplicate settle callbacks do not reset the committed clock. Playlist metadata overrides resolved hints. A missing resolver produces `.missingResolver`; it never constructs a fake playback URL. The future Core adapter will use namespace `hotmic` in a separate package.

## Terminal item failures

`HMPlayerConfiguration.failedItemPolicy` is `.skip` by default. After resolution exhausts its three attempts, or a native player reports a terminal media failure, the player emits `.error(item:kind:)` and advances to the first nonfailed entry after current. If none follows, it waits while a page is loading, or while `hasMoreContent` is true and the paging retry budget remains, so the source can supply a successor; after the source ends or its automatic retries are exhausted, it tries preceding entries in reverse order; if none remains, `currentItem` becomes nil and the snapshot becomes `.idle`. Entries remain in `items`. Automatic traversal remembers failed immutable entries and never resets their retry budgets, so all-failing playlists terminate. An untried candidate may itself fail; the same bounded traversal continues. Paging errors and recoverable cache-transport errors do not skip items. `currentIndex` is nil when empty or idle after failures; `activeIndex` remains zero for compatibility and does not prove `items[0]` is current.

```swift
let player = HMPlayer(configuration: HMPlayerConfiguration(failedItemPolicy: .stay))
// Or change an existing player's policy:
player.configuration.failedItemPolicy = .skip
```

`.stay` keeps the failed entry current and still emits the error. Explicit `jump(toID:)` (including the same ID), `next()` or `previous()` retries the selected failed entry; `replaceAll` starts a fresh failure traversal. Changing a failed item's immutable source/metadata makes it a new entry for this purpose. Merely editing another part of the playlist does not retry known failures.

With `HMVerticalFeedView`, automatic skips use the animated page request and commit only after scrolling settles. The feed internally tracks touches (including overlay scrubbing), dragging, deceleration and page animations; `isInteracting` is read-only. For controls outside the feed, call `beginInteraction()` on begin and `endInteraction()` on release/cancellation. Repeated begin calls renew a 30-second timeout, so a missing end cannot strand a failed item forever. A pending automatic page request/commit also waits for an interaction that starts after the request. A player with no feed surface commits the same navigation directly after interaction ends.

The following `NSURLErrorDomain` failures are retryable, including when nested in an AVFoundation error: `notConnectedToInternet`, `networkConnectionLost`, `timedOut`, `cannotFindHost`, `cannotConnectToHost`, `dnsLookupFailed`, `internationalRoamingOff`, and `dataNotAllowed`. They emit errors, retain the current item, and retry after 1, 2, 4, 8, 16, then at most 30 seconds between attempts, each wait jittered by ±25% so clients don't retry in lockstep; they never become terminal just because the viewer stays offline. While the error persists only the current and next entries retry; farther window entries keep their failure and retry once navigation makes them current or next. Resolution and native media failures use this classification. Retries pause when the feed is hidden. The player owns an `NWPathMonitor`, cancels it on teardown, and clears terminal/retry budgets on an unsatisfied-to-satisfied transition so entries can recover. No interface/network settings are changed. `HMFailedItemPolicy` is not Codable; benchmark serialization uses a private SPI mirror.

## Engagement

Engagement is three layers. Use the ones you need.

**1. Data and actions (`HotMicPlayer`).** `player.engagement(for: item)` returns the item's `@MainActor @Observable HMEngagement`. The player keeps it while the entry is in the prefetch window (or just behind current), and anywhere in the playlist once the viewer has sent, reacted or voted in it; otherwise it is rebuilt, and `engagementDidLoad` called again, when the entry comes back. Removed entries and `teardown()` release it. An item that isn't in the playlist (a cell animating out) gets an inert, empty engagement. For a reference, `engagement.item` becomes the resolved item once resolution finishes. Every query takes a media time, so seeking rewinds engagement with the video:

- `messages(near:lookback:limit:)`: chat from the last `lookback` seconds up to the playhead, oldest first, including the viewer's messages still sending.
- `polls(at:resultsLinger:)`: polls whose `opensAt..<closesAt` window contains the playhead, plus closed ones for `resultsLinger` seconds. `HMPoll.isOpen(at:)` decides whether voting is possible; `isClosed` lets a source end a poll early.
- `reactionTotals`, `density`, `markers` (waveform peaks, each a seek target), `authoredMoments`, `intensity(at:)`.
- Actions: `sendChat(_:at:)`, `react(_:at:)`, `react(_:toMessage:)`, `vote(pollID:optionID:)`. With no time given they use the item's current playback time. Chat shows at once as `.sending`; once the source accepts it, the engagement keeps it (and the viewer's stream reactions) in its own list as well as appending it to the timeline, so it survives scrubbing even when the timeline ignores `append`. Queries de-duplicate by ID, so an echo from the source is shown once; message reactions and votes update optimistically and roll back if the source throws. Unsupported actions throw `HMInteractionError.unsupportedAction` without touching state; validation failures throw `HMEngagementError`. `lastActionError` describes the latest failure. `lastReactionEcho` publishes the viewer's own stream reaction for an immediate animation.

**2. Your source (`HMInteractionSource`).** Implement `@MainActor HMInteractionSource` and pass it to `HMPlayer(interactions:)`; the player retains it. `timeline(for:)` returns an `HMStreamTimeline` without opening a session. Lifecycle hooks manage only current and next: `willBecomeNext`, `didBecomeCurrent`, `didLeave`. Promotion keeps the next session open; entries that leave both roles, disappear or tear down receive `didLeave`. Everything else is optional:

| Requirement | Default | Purpose |
| --- | --- | --- |
| `capabilities(for:)` | `.readOnly` | Which actions exist: `.sendChat`, `.reactToStream`, `.reactToMessage`, `.vote`. Components hide controls for the rest. |
| `polls(for:)` | `[]` | Polls on the item's media clock, read once when its engagement is created. |
| `sendChat`, `react`, `react(_:toMessage:for:)`, `vote` | throw `.unsupportedAction` | Perform the action against your backend. Return to confirm; throw to roll back. |
| `sendChat(_ message: HMChatMessage, for:)` | calls `sendChat(message.text, for:)` | Receives the client message ID; echo the message back with that ID and it is de-duplicated. |
| `engagementDidLoad(_:)` | nothing | Keep the `HMEngagement` **weakly** and push live state: `receive(_:)` for events from a socket, `update(_:)` for poll counts or closure, `updateReactions(_:forMessage:)` for message totals. An echo of the viewer's own event with the same ID is shown and counted once. |

Timeline events carry optional `avatarURL`, `wallTime` and per-message `reactions`. The player holds your source strongly and its engagements borrow it weakly; keep engagements weakly in the source. A standalone `HMEngagement(item:timeline:source:)` (previews, tests) retains its source. Without a source, the player uses an empty, read-only source: no events, polls or actions, never invented content. Demo engagement is opt-in Benchmark SPI: `HMPlayer(interactions: HMMockInteractionSource())` accepts every action after a simulated round trip and adds one poll per item.

**3. UI (`HotMicPlayerUI`, optional).** The components each take an `HMEngagement` and a media time (or a snapshot) and read `HMTheme` from the environment:

| Component | Shows |
| --- | --- |
| `HMChatRail` | Recent messages near the playhead; new ones push old ones out through a fade. Double-tap (or the VoiceOver action) reacts to a message. |
| `HMPollCard` | The visible poll: vote while open, then results with the viewer's choice. Read-only without `.vote`. |
| `HMFloatingReactions` | Reactions rising as the playhead crosses them, gated by the waveform under the playhead; the viewer's own reaction always animates. |
| `HMActionRail` | React (tap; long-press for the palette), Comment, Share (only with a handler), Mute (only with a binding). |
| `HMComposer` | One-line chat field; keeps text and shows an inline error on failure. |
| `HMEngagementScrubber` | Engagement waveform scrubber with tappable peaks; VoiceOver adjusts in 5% steps. |

`HMOverlayLayout` arranges them over full-screen vertical video. Add it with `HMVerticalFeedView(player: player, layout: HMOverlayLayout.self)`, or call `HMOverlayLayout(player:item:snapshot:options:)` inside your own overlay closure to add your own views around it. `HMOverlayLayout.Options` hides any part (chat, polls, floating reactions, scrubber, metadata, playback taps, individual rail buttons), wires Share (`onShare`) and sets chat lookback/limit and extra insets; apply them with `.hmOverlayOptions(_:)` or pass them directly. Scrubbing calls `beginInteraction()`/`endInteraction()` for you. The scrubber's drag is gesture state, so a drag cancelled by the feed, a page change or backgrounding resets without seeking and still ends the interaction; the layout also ends it when its cell stops being current or disappears, and only seeks while its cell is current.

`HMTheme` holds colors, Dynamic Type fonts, corner radius, SF Symbol names and the reaction palette; `HMTheme.default` is HotMic's look. Apply it once with `.hmTheme(_:)`. Text over video is always light on a scrim; cards use system materials and follow light and dark mode. All controls have VoiceOver labels; Reduce Motion replaces travel with fades and turns off ambient floating reactions; at accessibility text sizes the chat rail shows fewer, larger lines.

To write another layout, conform a view to `HMEngagementLayout` (`init(context: HMEngagementContext)`) and compose the components. The planned stacked and side-panel layouts need the video itself to move, so they will add a defaulted `videoPlacement` requirement that the feed reads; existing layouts keep compiling.

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

Each access to `events` creates an independent ordered subscription, buffering the newest 256 events; slow consumers can lose older events. Cancelling the consuming task releases that subscription. Observation clients can read `items`, `activeIndex`, `currentIndex`, `currentItem`, `snapshot`, paging state, `loadError` and `lastEvent`. Snapshots expose getters with internal setters; activation/frame flags are Benchmark SPI diagnostics. Subscribe before mutation when the first edit matters. TTFF is seconds in `HMPlayerEvent`; analytics `ttff_ms` remains milliseconds. Readiness is `resolving` while awaiting URL/format resolution. On activation it becomes `resolved`, `cachedBytes` or `warmPlayer`, preserved through the first frame; `cold` is the idle/unprepared default.

Create an `HMAnalyticsHub`, register sinks and pass `analytics:` to init. Existing `HMAnalyticsSink`, `HMConsoleSink` and `HMMuxAnalyticsSink` contracts remain. JSONL, mock timelines and the logging Mux bridge are Benchmark SPI. The real Mux bridge belongs to the host; see [Mux integration](../Integrations/Mux/README.md). `finishRun()` and transfer/prefetch-error/startup-summary/run-end telemetry are Benchmark SPI. `HMPlaybackEvent.Kind.rawValue` remains a stable string for sinks; the kind has no public `CaseIterable` or `RawRepresentable` conformance. Decoding recorded categories requires Benchmark SPI.

## Transport settings and limits

The default preset has two native players, a 128 MB disk cap and a fixed data window. Media prefetch waits for a safe current buffer. Resolution does not wait for that gate. The loopback listener publishes its port only after ATS/health verification; failure falls back to direct URLs. A dead listener is re-armed on next use or foreground, and each restart repeats the health check before publishing its port. Current requests use high priority and speculative requests have a separate low-priority session. Stream inactivity times out after 20 seconds of permitted upstream work; intentional full-buffer backpressure pauses that clock. HLS playlists are memory-only with configurable `configuration.playlistTTL` (default 30 seconds).

Use versioned VOD paths. Query parameters are preserved in cache identity; volatile signing-parameter tuning is Benchmark SPI. Shared known resources survive removal of another owner and the LRU remains a hard cap. Live, DRM, authenticated origins, signed-playlist renewal, HLS byte-range/alternate-audio coverage and concurrent active players sharing the same disk directory remain outside the supported contract. Playback UI is iOS/tvOS; macOS package tests exercise platform-independent logic.

## Stable configuration

Start from `.default`, `.instantStart` or `.highQuality`. The supported tuning surface is `poolSize` (1–4), `prefetch.ahead`/`behind` (0–8), `prefetch.bytesPerItem` (up to 8 MiB), optional `prefetch.secondsPerItem`, `cacheCapacityBytes`, `startupPeakBitRate` (bits/s, zero unrestricted), `playlistTTL` (memory-only, seconds), `loops`, `startsMuted`, `managesAudioSession` and `failedItemPolicy`. `HMPrefetchPolicy` also supplies `off`, `nextOnly`, `balanced` and `aggressive` window presets. For example:

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
