# Integrating HotMicPlayer

Engineer-facing. What you write, what you get, and what it costs you.

Every number on this page was measured against this repo. The commands are
included so you can re-run them.

---

## 1. What you actually write

The smallest complete integration is **20 lines**, and it is a real file in this
repo — [`Sample/HotMicPlayerDemo/Integration/MinimalIntegration.swift`](../Sample/HotMicPlayerDemo/Integration/MinimalIntegration.swift)
— compiled by the sample app's target so it cannot rot into a snippet that no
longer builds.

### Step 1 — point the SDK at your feed API (9 lines)

```swift
struct ClipFeed: HMFeedDataSource {
    func loadPage(cursor: String?) async throws -> HMFeedPage {
        let page = try await ClipsAPI.clips(after: cursor)
        return HMFeedPage(
            items: page.clips.map {
                HMMediaItem(id: $0.id, url: $0.hlsURL, posterURL: $0.posterURL, title: $0.headline)
            },
            nextCursor: page.nextCursor
        )
    }
}
```

There is no HotMic backend in this path. `HMFeedDataSource` is a protocol over
*your* content API and `HMMediaItem` is a value type you construct. Adopting the
player does not require moving your catalogue anywhere.

### Step 2 — render it, with your own overlay (7 lines)

```swift
struct FeedScreen: View {
    @State private var controller = HMFeedController(dataSource: ClipFeed())

    var body: some View {
        HMVerticalFeedView(controller: controller) { item, snapshot in
            HouseOverlay(item: item, snapshot: snapshot)
        }
    }
}
```

The overlay closure is the whole extensibility story. You get the `HMMediaItem`
and an `HMPlaybackSnapshot` — state, position, duration, buffered-ahead,
bitrate, stall count, time-to-first-frame, live/DVR window. What you draw is
yours. **The SDK ships no opinion about your brand.**

### Step 3 — wire analytics (4 lines)

```swift
@MainActor
func makeAnalytics(muxEnvironmentKey: String, viewerID: String) -> HMAnalyticsHub {
    let hub = HMAnalyticsHub()
    hub.add(HMMuxAnalyticsSink(environmentKey: muxEnvironmentKey, viewerUserID: viewerID))
    return hub
}
```

Mux is one sink. `HMAnalyticsSink` is a two-method protocol — a warehouse sink,
a Conviva sink or an internal Kafka sink is the same shape. See
[the Mux notes](../Integrations/Mux/README.md) for the production bridge.

---

## 2. What it costs you

| | Measured | How |
|---|---|---|
| Compiled ARM64 code (`__text`) | **250 KB** | `size -m HotMicPlayer.o` |
| Total `__TEXT` segment | **409 KB** | same |
| Linked object, stripped | **817 KB** | `strip -S -x` |
| Third-party dependencies | **0** | `Package.swift` |
| Non-Apple frameworks linked | **0** | AVFoundation, AVFAudio, SwiftUI, UIKit, Observation, QuartzCore, OSLog, Foundation |
| Bundled resources / assets | **0** | no asset catalog, no nibs, no fonts |
| SDK source | **2,419 lines** (1,765 excluding blanks and comments) | `wc -l` over `Sources` |
| Public API surface | 17 structs, 9 classes, 9 enums, 4 protocols | `grep '^public'` |
| Minimum iOS | **17.0** | `Package.swift` |

Reproduce:

```bash
xcodebuild -scheme HotMicPlayer -configuration Release \
           -destination 'generic/platform=iOS' -derivedDataPath /tmp/hmrel build
size -m /tmp/hmrel/Build/Products/Release-iphoneos/HotMicPlayer.o
```

The 250 KB figure is the code segment *before* your linker dead-strips anything
you don't call and before App Store thinning and compression. Treat it as a
ceiling, not an estimate.

**Source, not a binary.** Ships as a Swift package you can read, fork, step into
in the debugger and patch locally without waiting on us. That is a deliberate
reversal of how the previous HotMic player shipped.

---

## 3. What you get for it

The pieces that are tedious to build correctly, with the line counts of what you
would otherwise be writing yourself:

| Component | Lines | What it does |
|---|---|---|
| `Core` | 970 | Recycled `AVPlayer` pool, prefetch window, feed controller, live-edge tracking, audio session |
| `Analytics` | 437 | 17-event normalised telemetry model, sink fan-out, Mux adapter |
| `Timeline` | 371 | Engagement timeline, density aggregation, peak clustering |
| `Feed` | 361 | Paging feed view, data source protocol, page transitions |
| `Model` | 209 | Media item, configuration presets, playback snapshot |
| `Playback` | 65 | `AVPlayerLayer` host |

Three of those are where feed players usually go wrong.

**A bounded player pool.** The number of live `AVPlayer` instances — and
therefore decoder sessions — is exactly `configuration.poolSize` (default 4),
**independent of feed length**. A 5-item feed and a 5,000-item feed cost the
same. Eviction never touches an item inside the prefetch window, which is what
makes swiping backwards instant instead of a re-buffer.

**A prefetch window with a startup bitrate cap.** Neighbours are warmed
nearest-first with a small buffer target and a bitrate ceiling, so warming never
competes for bandwidth with the item on screen. The ceiling lifts once playback
is stable, so steady-state quality is not sacrificed for startup.

**Analytics that survive recycling.** Mux bills and reports per view, keyed to
the monitored player. The naive integration calls `monitorAVPlayerLayer` on cell
appear and `destroyPlayer` on disappear, which at feed scroll speed churns Mux's
registry several times a second and reports a fresh player rather than a new
video on the same one. `HMMuxAnalyticsSink` tracks pooled players by key and
emits `videoChangeForPlayer` on a recycle. You can watch it happen live in the
sample app's **Mux** tab.

---

## 4. Measured performance, and what still needs proving

Time-to-first-frame — "make this item visible" to first rendered frame — read
off the sample app's HUD:

| Source | Cold | Preloaded |
|---|---|---|
| Remote HLS (Mux ABR ladder) | **900–1,113 ms** | **150–370 ms** |
| Bundled local MP4 | — | **94–270 ms** |

**These are iOS 26.5 Simulator numbers on office wi-fi and are not a substitute
for device measurement.** The Simulator does not model a real radio, thermal
state or a shared cellular link. Quote them as the shape of the result, not the
result.

What a pilot should measure on real hardware against your catalogue:

- p50 / p95 time-to-first-frame, cold and preloaded, on LTE and wi-fi
- Rebuffer ratio and stall count per view
- Memory high-water mark across a 200-item scroll, at each pool size
- Scroll frame drops (the feed should hold 120 Hz on ProMotion)
- Battery draw per 10 minutes of continuous playback

The SDK already emits every one of those. `firstFrame` carries `ttff_ms`,
`rebufferStart` / `rebufferEnd` carry stall duration, `variantChanged` carries
indicated and observed bitrate. Instrumenting the pilot is not extra work — it
is the same event stream the HUD reads.

---

## 5. Three integration shapes

**A. Drop-in feed.** `HMVerticalFeedView` plus your overlay closure, ~20 lines.
This is what the sample app does.

**B. Bring your own container.** Use `HMFeedController` and `HMVideoSurface`
directly and keep your existing `UICollectionView` or paging logic. The
controller exposes `setActiveIndex(_:reason:)`, `node(for:)` and
`snapshot(for:)`; you own the scrolling.

**C. Engine only.** Take `HMPlayerPool` and `HMPlayerNode` and leave the SwiftUI
layer entirely. This is the path if you have a UIKit player surface you are not
replacing.

All three are the same package. There is no "SDK mode" to opt into, and B and C
do not require forking.
