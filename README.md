# HotMicPlayer

A vertical-feed video player SDK for iOS, and a sample app that demos it.

> **Prototype.** Video playback is real AVFoundation over bundled clips. The
> feed API, engagement events (chat / reactions / markers) and the Mux transport
> are simulated behind protocols, so the whole thing runs with no backend and no
> third-party dependencies. See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Run the demo

```bash
open Sample/HotMicPlayerDemo.xcodeproj
# pick an iPhone simulator, ⌘R
```

Or from the command line:

```bash
xcodebuild -project Sample/HotMicPlayerDemo.xcodeproj \
           -scheme HotMicPlayerDemo \
           -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
           build
```

Requires Xcode 16+ / iOS 17+.

## What to show, in order

The app opens on a **playlist** of six vertical clips, and the feed is a
full-screen push from it. That split is deliberate: it lets you leave the feed
and jump back into it at an arbitrary index, which is what actually exercises
deep-linking, position restore and the warm window.

1. **The playlist.** Note the `⚡ warm` badges on the first few rows — those are
   the items the pool has already buffered while you were browsing. Nothing is
   playing yet.
2. **Tap "Play the reel"** and swipe. Real vertical inventory at four different
   source aspects (9:16, 4:5, 1:1, 3:4), all filled to the screen. Every swipe
   lands in ~100–250 ms with `PRELOADED` in the HUD.
3. **Panel → Player → Preloading → Off**, then swipe again and watch the HUD.
   Set it back to `3 / 2` and it snaps back.
4. **The panel button → Mux.** One `monitorAVPlayerLayer` per pool slot, then
   `videoChangeForPlayer` on each recycle — not a teardown per cell. That
   distinction is what most feed integrations get wrong.
5. **The scrubber.** It's an engagement waveform, not a progress bar: bar height
   is how loud chat was at that moment, and the emoji mark clustered reaction
   peaks. Emoji only fly up where the rail is elevated, so the two read as one
   thing. Drag it and a timecode bubble tracks your thumb showing what happened
   there — and chat and reactions rewind with the playhead, because overlays
   render from `(clock, timeline)` rather than from arrival order.
6. **Tap the flame a few times.** Your reactions are written onto the timeline
   at the playhead, so the waveform grows under you. Scrub back over that spot
   and they replay — they're events on the timeline now, not an animation.
7. **Panel → Fill screen.** Off shows the true source frame, which makes the
   1:1 and 4:5 clips obvious. On crops them to vertical.
8. **Panel → Transition.** Fade, scale, parallax, cube, cover.
9. **Panel → preset.** Instant start vs High quality.

One button in the toolbar opens everything: player tuning, the live event log
and the Mux beacons. Tapping the HUD itself dismisses it when you want to show
the feed clean.

### Two paths the reel no longer covers

The reel is all local files, which means neither of these is visible in the app
as it stands:

- **Cold start.** Local clips load fast enough that preloading barely moves the
  number. The contrast is only dramatic over the network. Add a remote HLS item
  to `DemoContent.clips` if you want to show it.
- **Live / DVR.** `HMLiveWindowTracker` and the live-edge rendering are built and
  tested, but nothing in the reel is a live stream, so that path is dormant. Any
  HLS URL served without an `EXT-X-ENDLIST` will light it up.

## Using the SDK

```swift
import HotMicPlayer

let controller = HMFeedController(
    dataSource: MyFeedAPI(),                 // your paginated content source
    configuration: .instantStart,
    analytics: hub
)

HMVerticalFeedView(controller: controller, transition: .fade) { item, snapshot in
    MyOverlay(item: item, snapshot: snapshot)
}
```

`HMFeedController` owns the item list, the active index, the recycled player
pool, the prefetch window and analytics fan-out. Views observe it; they never
drive playback directly.

### Tuning

```swift
var configuration = HMPlayerConfiguration.default
configuration.prefetch = HMPrefetchPolicy(ahead: 5, behind: 1, bytesPerItem: 800_000)
configuration.poolSize = 2
configuration.startupPeakBitRate = 1_600_000   // small first segment, then lift
configuration.steadyBufferDuration = 10
controller.configuration = configuration       // safe to change at runtime
```

Default: two players plus bounded disk prefetch (S3). Presets: `.default`,
`.instantStart`, `.highQuality`, and `.preset(.S0/.S1/.S2/.S3)` for comparisons.
The data window does not allocate players. See [architecture](docs/ARCHITECTURE.md)
for buffer gating, cache transport and timing limits, and
[benchmarking](docs/BENCHMARKING.md) for remote playlists and headless device runs.

### Analytics

```swift
final class MySink: HMAnalyticsSink {
    let sinkName = "warehouse"
    func handle(_ event: HMPlaybackEvent, item: HMMediaItem) {
        // viewStart, firstFrame (ttff_ms), rebufferStart, variantChanged, …
    }
}

hub.add(MySink())
hub.add(HMMuxAnalyticsSink(environment: env, bridge: MuxDataBridge()))
```

Wiring the real Mux SDK is two steps — see
[`Integrations/Mux/README.md`](Integrations/Mux/README.md).

## Swapping in real content

`DemoContent.reel` is the only place content is defined. Bundled clips live in
`Sample/HotMicPlayerDemo/Resources/` as `<id>.mp4` plus a matching `<id>.jpg`
poster; the Xcode target uses a synchronized file group, so dropping files in
that folder is all it takes for them to ship.

Posters were generated with:

```bash
ffmpeg -ss 1 -i clip.mp4 -frames:v 1 -vf "scale=720:-2" -q:v 4 clip.jpg
```

## Docs

- [`docs/INTEGRATION.md`](docs/INTEGRATION.md) — how a host app adopts this, what
  it costs (measured: 250 KB, 0 dependencies), and the three integration shapes.
- [`docs/POSITIONING.md`](docs/POSITIONING.md) — why a publisher would pick this
  over rolling their own, argued honestly including where we don't differentiate.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — how it works and what is
  deliberately not built yet.

## Layout

```
Package.swift                    SPM manifest
Sources/HotMicPlayer/            the SDK
  Model/                         HMMediaItem, configuration, snapshot
  Core/                          player node, pool, feed controller, audio
  Playback/                      AVPlayerLayer host
  Feed/                          vertical feed view, data source, transitions
  Timeline/                      engagement timeline + mock generator
  Analytics/                     event model, hub, console sink, Mux adapter
Sample/HotMicPlayerDemo.xcodeproj
Sample/HotMicPlayerDemo/         the demo app (playlist + feed)
Integrations/Mux/                drop-in real Mux bridge + notes
Tests/HotMicPlayerTests/
docs/ARCHITECTURE.md
```

## Tests

```bash
swift test
```

Covers the pure logic: prefetch window ordering, seekable-window progress math
(including DVR), mock timeline determinism and density normalisation, feed
pagination, Mux payload mapping and page-transition clamping.
