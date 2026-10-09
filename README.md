# HotMicPlayer 0.3.1

A zero-dependency partner SDK for iOS 17+ apps embedding a vertical VOD playlist. MP4 and HLS can share one playlist. `HMPlayer` owns playlist edits, playback and events; `HMVerticalFeedView` renders video with your overlay.

```swift
import HotMicPlayer

@MainActor
func makePlayer() -> HMPlayer {
    let player = HMPlayer(configuration: .default)
    player.replaceAll([
        HMMediaItem(id: "intro", source: .url(introURL, format: .mp4)),
        HMMediaItem(id: "replay", source: .url(replayURL, format: .hls))
    ])
    return player
}

HMVerticalFeedView(player: player) { item, snapshot in
    MyOverlay(item: item, snapshot: snapshot)
}
```

URL items play directly. Opaque `.reference(namespace: "partner", id: "clip")` items require an `HMItemResolver`. `HMPlaylistSource` supplies pages, and `HMInteractionSource` supplies engagement timelines and optional actions. The default interaction source is a deterministic demo. The future `HotMicPlayerCore` adapter will live in a separate package; this package has no Core dependency.

| Playlist operation | Playback effect |
| --- | --- |
| `replaceAll(_:startAt:)` | Switches to the selected entry; empty becomes idle |
| `replaceUpcoming(_:)` | Replaces entries after current; current keeps playing |
| `insertNext(_:)` | Inserts after current; current keeps playing |
| `append(_:)` | Appends at the end; current keeps playing |
| `remove(ids:)` | Preserves current unless removed; then next survivor, then previous |

Edits are atomic on the main actor, return a success Boolean and emit clear errors for duplicates or invalid inputs. Swipes commit by item ID. An edit cancels the move only when current or destination changes position; appends preserve it. Empty append/insert and unknown removals are silent no-ops. Completed resolutions are session-cached; pending resolutions and speculative downloads leave with their window. Removed entries release their cache ownership while shared known resources remain reusable.

A current reference starts automatically when resolution completes, including its video surface. Its readiness is `resolving` until the URL/format arrives; TTFF includes resolution time from the selection tap or page commit (settle). Swipe and programmatic-page timing begins at commit; duplicate commits cannot reset it.

Terminal item failures emit an error and follow `HMPlayerConfiguration.failedItemPolicy`: `.skip` (default) tries the next nonfailed entry, then previous, then idle; `.stay` keeps the failed entry selected. Skips wait for a settled page and for dragging/scrubbing (`player.isInteracting`, read-only) to end. Failed entries remain in the playlist and are excluded from automatic traversal, so an all-failing list stops.

Use `play()`, `pause()`, `seek(to:)`, `next()`, `previous()`, `jump(toID:)` and `isMuted`. SwiftUI observes player state and immutable playback snapshots. Each `events` access creates an independent `AsyncStream<HMPlayerEvent>` subscription. Analytics hub/sinks remain available, including console and the optional host-provided Mux bridge.

The default engine uses two native players and a bounded disk media cache. Partner presets are `default`, `instantStart` and `highQuality`. Experimental strategies, JSONL and benchmark controls require `@_spi(Benchmark) import HotMicPlayer`. Engine nodes, pools, video surfaces and loopback transport are internal.

## Changelog

### 0.3.1

- Fixed delayed reference activation/rendering for HLS and MP4. Swipe and programmatic-page TTFF start at page commit, preserving comparison with 0.3.0.
- Added `HMReadinessTier.resolving`. **Source compatibility:** exhaustive switches over readiness must handle this new case.
- Added public `failedItemPolicy`: `.skip` by default or `.stay`. Terminal failures skip only after interaction ends; paging gets a chance to supply the next item before previous-item fallback.
- Added read-only `isInteracting`, driven by feed touches and page motion. Host controls outside the feed can use `beginInteraction()` / `endInteraction()`; an unmatched begin expires after 30 seconds.
- Connectivity/timeout errors stay selected and retry with bounded backoff. An owned `NWPathMonitor` clears remembered terminal failures when connectivity returns.
- Added `currentIndex: Int?`, nil when idle. `activeIndex` keeps its compatibility value of zero while idle and must not be used alone to infer a current item.

## Sample and Playlist lab

```bash
open Sample/HotMicPlayerDemo.xcodeproj
```

Select an iPhone simulator and run. The sample uses the public API plus Benchmark SPI; `MinimalIntegration.swift` uses only the public API. Browse the bundled reel, open the feed, or tap **Playlist lab** to edit a playing list. The lab shows every operation, duplicate rejection, removal of current, empty state, navigation and delayed edits during a swipe. Paging race supplies delayed overlapping pages; the cursor and event logs prove progress through duplicates. It logs activation/position/frame continuity to `Documents/playlist-lab-operations.jsonl` and playback analytics to `Documents/BenchRuns/`.

For the lab's mixed MP4/HLS content, generate the HLS fixture from the bundled reel with an existing ffmpeg installation, then start the local bench origin:

```bash
python3 bench/prepare_lab.py
python3 bench/origin.py --root bench/generated --port 8088
```

The default origin field is `http://127.0.0.1:8088` for the simulator. On a physical device use the reachable address of your owned bench host. All media fixtures and results are ignored by Git. Backgrounding the lab pauses playback; returning resumes the prepared current item.

For the delayed-reference repro, launch the Sample with `--hm-reference-lab 1` and serve the generated HLS fixture on port `18088`. The lab covers initial selection, jump, swipe and insert/next for HLS and MP4, plus resolution/media failures, `.stay`, interaction deferral and end fallback. Evidence is written to `Documents/reference-lab*.jsonl`.

## Documentation and validation

- [0.3.1 review-fix validation](docs/PLAYER_0.3.1_REVIEW_FIXES.md): current simulator evidence, commit-based TTFF and final build/test results.
- [0.3.1 initial validation](docs/PLAYER_0.3.1_VALIDATION.md): historical before/after activation repro for the first review.
- [Integration](docs/INTEGRATION.md): minimal adoption, paging, references, engagement and events.
- [Architecture](docs/ARCHITECTURE.md): playback, prefetch, cache ownership and overlay-by-clock model.
- [Public API inventory](docs/PUBLIC_API.md): every exported type and function.
- [Benchmarking](docs/BENCHMARKING.md): milestone 1's benchmark mode and device workflows.
- [Milestone 2 validation](docs/MILESTONE_2_VALIDATION.md): initial simulator evidence.
- [Review fixes and validation](docs/MILESTONE_2_REVIEW_FIXES.md): all ten fixes, API visibility checks, simulator races and final build/test timings.

`swift test` exercises platform-independent playlist, resolver, cache and timeline logic. The Sample app and simulator flow exercise the native iOS engine. Generic device builds can use `CODE_SIGNING_ALLOWED=NO`; no signing setup is required for compilation.

Paging failures use four total attempts with 1/2/4-second retry delays, then wait for navigation or an explicit `loadNextPage()`. `replaceAll` restarts the playlist source cursor at nil. Hosts that own `AVAudioSession` can use `HMPlayerConfiguration(managesAudioSession: false)`; `loops` and `startsMuted` are also public settings. See [integration contracts](docs/INTEGRATION.md).
