# HotMicPlayer 0.3.0

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

Use `play()`, `pause()`, `seek(to:)`, `next()`, `previous()`, `jump(toID:)` and `isMuted`. SwiftUI observes player state and immutable playback snapshots. Each `events` access creates an independent `AsyncStream<HMPlayerEvent>` subscription. Analytics hub/sinks remain available, including console and the optional host-provided Mux bridge.

The default engine uses two native players and a bounded disk media cache. Partner presets are `default`, `instantStart` and `highQuality`. Experimental strategies, JSONL and benchmark controls require `@_spi(Benchmark) import HotMicPlayer`. Engine nodes, pools, video surfaces and loopback transport are internal.

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

## Documentation and validation

- [Integration](docs/INTEGRATION.md): minimal adoption, paging, references, engagement and events.
- [Architecture](docs/ARCHITECTURE.md): playback, prefetch, cache ownership and overlay-by-clock model.
- [Public API inventory](docs/PUBLIC_API.md): every exported type and function.
- [Benchmarking](docs/BENCHMARKING.md): milestone 1's benchmark mode and device workflows.
- [Milestone 2 validation](docs/MILESTONE_2_VALIDATION.md): initial simulator evidence.
- [Review fixes and validation](docs/MILESTONE_2_REVIEW_FIXES.md): all ten fixes, API visibility checks, simulator races and final build/test timings.

`swift test` exercises platform-independent playlist, resolver, cache and timeline logic. The Sample app and simulator flow exercise the native iOS engine. Generic device builds can use `CODE_SIGNING_ALLOWED=NO`; no signing setup is required for compilation.

Paging failures use four total attempts with 1/2/4-second retry delays, then wait for navigation or an explicit `loadNextPage()`. `replaceAll` restarts the playlist source cursor at nil. Hosts that own `AVAudioSession` can use `HMPlayerConfiguration(managesAudioSession: false)`; `loops` and `startsMuted` are also public settings. See [integration contracts](docs/INTEGRATION.md).
