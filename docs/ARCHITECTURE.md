# HotMicPlayer — architecture

Status: **prototype.** Real AVFoundation playback over bundled clips; the feed
API, engagement events and Mux transport are simulated behind protocols. The
point is to make the shape of the SDK demonstrable before committing to backend
work.

## Layers

```
┌──────────────────────────────────────────────────────────┐
│ HotMicPlayerDemo (sample app)                             │
│  playlist → feed · overlays · control panel · HUD         │
│  analytics console · consumes only the SDK's public API   │
└───────────────────────┬──────────────────────────────────┘
                        │
┌───────────────────────▼──────────────────────────────────┐
│ HotMicPlayer (SPM)                                        │
│                                                           │
│  Feed        HMFeedController · HMVerticalFeedView         │
│              HMFeedDataSource · HMPageTransition           │
│  Core        HMPlayerPool · HMPlayerNode · HMAudioSession  │
│  Playback    HMVideoSurface (AVPlayerLayer host)           │
│  Timeline    HMStreamTimeline · HMTimelineEvent            │
│              HMDensityBucket · HMTimelineMarker            │
│  Analytics   HMAnalyticsHub · HMAnalyticsSink              │
│              HMMuxAnalyticsSink · HMMuxBridge              │
│                                                           │
│  deps: AVFoundation, SwiftUI, Observation. Nothing else.   │
└──────────────────────────────────────────────────────────┘
```

No Bitmovin, no OpenTok, no image library, no networking library. The dependency
list is the product claim: "lightweight wrapper around the native player" is only
true if you can read the whole dependency graph in one line.

## The three decisions that matter

### 1. A pool of players, not a player per cell

`HMPlayerPool` holds a fixed number of `HMPlayerNode`s (default 4). Each node owns
one `AVPlayer` and one `AVPlayerLayer`. As the viewer scrolls, nodes are recycled
onto new items; the layer travels with the node.

Two consequences worth knowing:

- Decoder sessions are capped, so a 500-item feed costs the same as a 5-item one.
- Beacon-style analytics SDKs stay attached to a stable player across a recycle,
  which is why the Mux adapter can emit `videoChange` instead of tearing down and
  re-monitoring. See `Integrations/Mux/README.md`.

Eviction never touches an item inside the current prefetch window, which is what
makes swiping back instant rather than a re-buffer.

### 2. Preloading is a window, and it's tunable

`HMPrefetchPolicy` declares how many items ahead and behind to warm.
`HMFeedController.prefetchWindow(around:)` warms them nearest-first, so the item
most likely to be swiped to gets bandwidth priority.

A warmed item is attached to a player and buffering, but paused, with a *small*
buffer target and (optionally) a bitrate ceiling — warming a neighbour must never
compete with the item on screen. On activation the buffer target and ceiling are
raised.

`HMPlayerConfiguration.startupPeakBitRate` caps ABR for the first few seconds so
the first segment is small, then lifts. This is the single biggest lever on
time-to-first-frame, and the sample app's HUD shows the result directly:
roughly **1000 ms cold vs 150 ms preloaded** on the bundled test streams.

### 3. Overlays are a function of (clock, timeline)

Adapted from the earlier planning notes, and it is the idea the differentiated
features hang off.

```swift
protocol HMStreamTimeline {
    var duration: TimeInterval { get }
    func events(in range: ClosedRange<TimeInterval>) -> [HMTimelineEvent]
    var density: [HMDensityBucket] { get }
    var markers: [HMTimelineMarker] { get }
}
```

Overlays never ask "am I live?". They ask for a time window and render what comes
back. Live, DVR and VOD are then one code path, and scrubbing backwards replays
the chat and reactions for free — which the sample app demonstrates.

Aggregation is precomputed. `density` and `markers` are built once when the
timeline is constructed, never recomputed on a time tick, and `events(in:)`
binary-searches rather than filtering — it is called from overlay bodies on
every tick.

Ambient event volume is tied to the **bucket count, not the clip length**.
Scaling it with duration either leaves a short clip's rail empty or floods a long
one. Within that budget the three signals are deliberately unbalanced: reactions
carry the engagement volume the waveform is drawn from, chat is kept sparse
because it is the signal a human actually reads, and peaks run about ten times
ambient once concentrated into the few buckets they span. That ratio is what
makes the floating reactions visibly surge when the playhead reaches a marker
rather than streaming constantly.

The overlay emits one floater per fixed amount of reaction weight in the window
the playhead just crossed, rather than one per event — so the on-screen rate
tracks the timeline without trying to render several hundred events a second.
Emission is additionally gated on the height of the density bar under the
playhead: ambient reactions exist to give the rail a continuous waveform, but
they are not *moments*, and flying emoji while the rail looks flat reads as the
two being unrelated. Gating on the same array the bars are drawn from means
emoji appear exactly where you can see something happening. The threshold lives
in the app but the separation it depends on is asserted in the SDK's tests.

One subtlety: overlays index the timeline by a **wrapped** offset, not the media
clock. A looping clip replays its own engagement, and a live stream — whose media
clock runs indefinitely past the mock timeline's span — keeps receiving events
instead of falling silent once it passes the end.

`HMStreamTimeline.append(_:)` folds a new event into the aggregates. That is the
path a viewer's own reaction takes in the demo, and in production it is also how
a live socket would feed the timeline — same entry point, so a locally-echoed
reaction and one that arrived over the wire behave identically, including on a
scrub-back. Bucket weights are kept as live state, so an append costs a
60-element rebuild rather than a rescan of every event. A replay timeline over
fixed history has nothing to append to, so the protocol's default does nothing.

`markers` are derived from `density` rather than from the raw events. Clustering
the events independently lets a marker land where the rail looks flat, which
reads as a bug; taking local maxima out of the same array the bars are drawn
from means a marker always sits on a peak you can see.

The scrubber follows the same rule. Its bars are a `Shape` whose geometry
depends only on the density array, drawn twice (dim underneath, bright on top)
with the bright copy revealed by a mask. A time tick resizes that mask; it never
rebuilds the path.

Today the only implementation is `HMMockTimeline`, seeded deterministically from
the item id so the same clip looks identical every run. Production would need a
`LiveStreamTimeline` over `HotMicSDK`'s `StreamSession` callbacks and a replay
implementation over a windowed history endpoint.

## Live and DVR

The player derives its scrubbing range from `seekableTimeRanges` rather than
`duration`, because HLS reports duration as indefinite on live. `HMPlaybackSnapshot`
carries `seekableStart`, `duration` (the live edge) and `isLive`, and `progress`
is measured *inside* the seekable window. The demo reel is currently all local
files, so this path is dormant in the app — any HLS URL served without an
`EXT-X-ENDLIST` exercises it.

That range cannot be used raw. It is a manifest artefact, and it misbehaves in
two independent ways: the edge only moves when a refresh lands (in jumps of one
target duration, while `currentTime` advances continuously), and the depth
toggles by a segment as the window is trimmed. Either one alone renders as the
playhead sliding backwards every couple of seconds while the video plays on.

`HMLiveWindowTracker` fixes both, and the distinction between them matters:

- The **edge** is extrapolated with the wall clock between refreshes and snapped
  forward when the manifest catches up. It is monotonic by construction, and
  bounded so media/wall clock drift cannot accumulate.
- The **depth** is a running maximum with a slow decay, *not* an average. The
  trimming pattern is a slow square wave, so any low-pass fast enough to follow
  a real DVR change still follows the noise. A maximum reads the depth the
  stream is actually offering; the decay keeps it honest if that depth shrinks.

Measured on the bundled live stream, this took the playhead from a ±24px
sawtooth to sub-pixel. `LiveWindowTrackerTests` replays that manifest behaviour,
and includes a test asserting the *unsmoothed* signal still jitters — if that
ever stops being true, the smoothing has stopped earning its keep.

## Analytics

The core emits `HMPlaybackEvent`s to `HMAnalyticsHub`, which fans out to any
number of `HMAnalyticsSink`s. The core has no knowledge of Mux.

Event kinds cover the union of what Mux, Conviva and product analytics want:
`viewStart`, `viewEnd`, `loadStart`, `firstFrame`, `play`, `playing`, `pause`,
`seeking`, `seeked`, `rebufferStart`, `rebufferEnd`, `variantChanged`, `ended`,
`error`, plus feed-specific `preloadStart`, `preloadReady` and `playerRecycled`.

Two sinks ship: `HMConsoleSink` (ring buffer + OSLog, drives the demo's console)
and `HMMuxAnalyticsSink`.

## What is deliberately not built yet

- `OverlaySlot` / `OverlayPlugin` registry. The sample app composes overlays
  directly. Worth doing once there are two real consumers, not before.
- Landscape, theater and inline embed layouts. The brief was vertical-first.
- `PlayerTheme` as a value type. The demo has a small local `DemoTheme` instead.
- Scrub preview thumbnails (HLS I-frame playlists).
- A real `PlaybackEngine` protocol. `HMPlayerNode` is concrete AVFoundation. The
  seam is small enough to introduce later if low-latency HLS forces a second
  engine — but that decision should be driven by a latency requirement, not
  anticipated.

## Known rough edges

- The bundled sample streams are landscape 16:9. `resizeAspectFill` crops them to
  vertical, which is realistic but not flattering. Real vertical content will
  land in `DemoContent.reel`.
- The feed uses SwiftUI's paging scroll behaviour. It is good, but a
  `UICollectionView` would give finer control over cell lifecycle if profiling
  ever demands it.
- Swift language mode 5. Migrating to 6 is mechanical (the design is already
  `@MainActor`-isolated throughout) but was not worth doing mid-prototype.
