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

### 1. Two players and a separate data window (S3 default)

The app supplies a playlist to `HMFeedController(items:configuration:analytics:)`
or a paginated data source to the same controller. The default allocates exactly
**two** `AVPlayer`s. The active node plays; once it is safely buffered, the next
node loads and prerolls at rate 1 without advancing the playback clock. Its
`AVPlayerLayer` stays attached to the neighbouring surface. A forward page commit
promotes that node, and recycles the old current node for the next neighbour.
The current item is always protected; warm offsets are truncated to the actual
pool capacity so a large data window cannot recycle the active player.

`HMPrefetchPolicy` independently defaults to five ahead and one behind,
nearest-first, with an 800,000-byte budget per item, a three-second current-buffer
threshold, and a 128 MB disk cap. Short clips qualify when their remaining media
is fully buffered. Falling below the threshold cancels speculative data tasks;
S3 also detaches warm items when buffer safety is lost after startup. Page
commits invalidate the prefetch generation immediately. The cache pins the current
window preferentially, but its hard cap wins even over pins. Disk entries are
range chunks with a persisted LRU index; interrupted/unindexed files are removed
on opening. Cache identity is scheme/host/path, independent of signed query
strings. **Content and non-signature query variants must have versioned paths.**

Strategies are presets with independently overridable knobs: S0 is one player
with no prefetch, S1 one player with disk prefetch, S2 the original competing warm
pool (2/3/4 players), and S3 the hybrid. All remote VOD strategies traverse the
same proxy, so transport overhead is common to the comparison. S0/S2 neither read
nor write the disk cache. Live streams retain AVFoundation's direct transport.

### 2. Transport spike, 2026-10-08

We selected a loopback HTTP proxy implemented with `NWListener` and
`URLSession`, with no third-party dependencies. The listener binds **only
127.0.0.1**, on an ephemeral port, and exposes opaque per-item routes through
`localhost`. There is no arbitrary URL endpoint. MP4 and HLS fMP4 were encoded
from all six bundled clips and played on a dedicated **iPhone 17 Pro / iOS 26.5
simulator**. Screenshots showed the correct video; JSONL first-frame, playback,
access-log and network/cache events accompanied it. A four-swipe HLS
`backAndForth` run completed with five matched first-frame events and no decoder
or transport errors. This confirms the chosen path for these VOD fixtures; it
is not evidence about all HLS features or physical-device performance.

The first spike exposed two failures: returning a shortened 206 response for
AVFoundation's large open-ended MP4 Range caused item failure, and async
byte-at-a-time reading took seconds in a Debug build. The working version honors
the **entire requested Range**, streams it in bounded 512 KiB blocks, and uses
block-based URLSession delegates. Invalid/multiple ranges return 416. Cancellation
closes the response and upstream task. Upstream origins must support Range for
nonzero offsets; an origin ignoring Range can supply the initial prefix but
cannot serve later seeks correctly.

HLS master/media URI lines and quoted URI attributes (MAP, KEY, MEDIA, etc.) are
rewritten, resolving relative references against the final redirected URL. The
raw playlist's final base URL is persisted with the bytes. Prefetch chooses one
rendition at or below the startup cap (lowest if none fit), caches the playlists,
init segment, then nearest first segments up to the byte budget. A seconds
budget stops at a segment boundary; a byte budget may cache a segment prefix.
MP4 seconds budgets estimate bytes from known duration and file length, with the
byte ceiling still enforced. HTTP payload bytes are counted, including received
bytes on cancellation; protocol/TLS overhead is not counted.

We did not build an AVAssetResourceLoader HLS-segment path: HTTP rewriting provides
an observable, working common path for both fixtures. Future coverage needs
byte-range HLS, alternate audio, encryption/DRM, live/LL-HLS, redirects, signed
playlist refresh and authenticated origins on real hardware. Playlists currently
have no expiry, so the cache is for immutable **VOD** assets with versioned paths.
The SDK does not alter ATS policy. Debug LAN HTTP permission belongs exclusively
to the Sample target; production hosts must allow loopback networking as required
by their OS and continue serving upstream media over HTTPS.

### Timing and byte accounting

One monotonic clock (`ProcessInfo.systemUptime`) timestamps requests and events.
`start()` records its play request before content loading; the sample's Play tap
calls `requestPlay(at:)` before presentation and asset work. Browsing the playlist
loads metadata, without warming the first video. On iOS 17, a delegate bridge
commits pages at `scrollViewDidEndDecelerating` / a drag ending without deceleration,
rather than when `scrollPosition` changes during a drag. The bridge forwards the
other delegate callbacks to SwiftUI.

`AVPlayerLayer.isReadyForDisplay` KVO reveals the layer directly. The visible
surface waits for a subsequent display-link boundary, after observing that ready
layer attached to a visible window, before emitting `firstFrame`. This includes
the actual layer-swap/presentation delay of already-ready players, and resets per
activation/back-swipe. There is **no media-time polling in TTFF**. The 100 ms
periodic observer remains only for the scrubber/buffer state. Readiness alone is
not a display timestamp ([Apple's property documentation](https://developer.apple.com/documentation/avfoundation/avplayerlayer/isreadyfordisplay)); the display-boundary detector is a presentation estimate
with roughly a refresh-period uncertainty, not a physical-panel photodiode
measurement. Physical iPhone validation is still required.

Each activation records warm-player/cached-bytes/cold tier, item status, buffered
seconds ahead and cached bytes. `wasPreloaded` reflects real readiness, not elapsed
warm time. View IDs correlate startup summaries and first frames. Summaries clip
stall count/time to the first ten wall-clock seconds after the request, emitting
an observed-window length when the viewer leaves early. Startup bitrate comes
from access logs; resolution comes from a pixel buffer sampled at the first presentation boundary
(with an explicitly labeled presentation-size fallback if unavailable).
View/first-frame events sample player count and task physical memory footprint.
Decoder, transport and speculative failures have separate events.

Network and cache payload bytes are attributed to item routes. Wasted prefetch is
received speculative bytes minus the union of prefetched ranges supplied to
**activated** playback, including data supplied while warm and subsequently
activated; repeated probes do not count twice. It includes cancelled/discarded
bytes. This is a transport-consumption metric, not the number of pixels watched.
The JSONL sink serializes ordered events off the main actor, writes a complete
run/configuration/device/build header, and has an explicit durable flush barrier.

Poster URLs render until a decoded layer is ready. Runtime first-non-black-frame
generation is deferred: a partial MP4 may lack metadata or the needed GOP, HLS
requires assembling init/segments, and AVAssetImageGenerator would allocate
additional decoding work. A future worker needs a background decode budget,
cancellation tied to the window, black-frame scoring and cached thumbnail files.
The encoder generates supplied poster images at one second for the fixtures.

The Sample's benchmark mode fetches a URL-supplied grid, runs cells/repetitions
in-app, and posts each flushed run to a configurable receiver. It remembers the
last grid URL and retains local JSONL on upload failure. Autopilot requests scroll
animations; touch and autopilot both activate only in the settled-page callback.
XCTest is a launcher/waiter for that same runner. See BENCHMARKING for Linux USB
installation, Device Farm artifact packaging and the manual-only build workflow.

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

Three sinks ship: `HMJSONLFileSink`, `HMConsoleSink` (ring buffer + OSLog, drives the demo's console)
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
