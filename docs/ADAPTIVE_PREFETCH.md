# Measured adaptive prefetch

`HMPlayerConfiguration.adaptive` defaults to `true`. `prefetch.ahead`, `behind`,
`bytesPerItem`, optional `secondsPerItem`, `cacheCapacityBytes`, `poolSize`,
`maxPrefetchConcurrency` and startup/steady bitrate ceilings are app limits.
The policy only reduces them. Set `adaptive: false` to use fixed budgets and the
existing buffer threshold/hysteresis; custom providers are bypassed in fixed mode.
Zero bitrate means uncapped; zero cache capacity prevents explicit disk prefetch.

```swift
var configuration = HMPlayerConfiguration(adaptive: true)
configuration.prefetch = HMPrefetchPolicy(ahead: 5, behind: 1, bytesPerItem: 800_000)
let player = HMPlayer(configuration: configuration)
// Optional: player.prefetchPolicy = PartnerPrefetchPolicy()
```

`HMPrefetchPolicyProviding.decide(_:configuration:)` accepts `HMPrefetchInputs`
and returns `HMPrefetchPlan`. `HMAdaptivePrefetchPolicy` is the stateless default;
`wasPaused` and `previousPlan` carry buffer and speed-tier hysteresis explicitly. Inputs and Plan have no Codable conformance; thresholds are Benchmark SPI tuning. A partner provider receives the same
smoothed measurements. A custom `HMPrefetchPolicyProviding` implementation must
keep its own hysteresis state: the default policy’s previous speed tier and
latency-override state are internal and are not exposed to custom providers.
The engine clamps every returned plan and independently
enforces buffer safety. `player.prefetchPlan` exposes the last applied plan.

The readiness tiers are:

1. `warmPlayer`: the nearest next entry is prepared/prerolled in the second player.
2. `cachedBytes`: at least `minimumCachedStartBytes` (Benchmark SPI, measurement only) payload bytes are on disk
   (default 32 KiB, bounded by a positive app per-item prefix budget). This
   excludes tiny native probes; it does not guarantee a complete decoded frame.
3. `resolved`: media URL and poster metadata are resolved, with no ready player or disk prefix.

`resolveAhead` (default 8, bounded to 32) controls the metadata-only horizon.
The cache window follows distance order with forward entries first at equal
distance. Binge misses suppress behind work and focus on +1/+2. The default
hybrid uses two players; explicit benchmark strategies retain their player knobs.
A long dwell delays ready-player and disk work from activation, then uses a deeper
budget. URL/poster resolution continues regardless of buffer safety or media pauses.
Stalls/unsafe buffers cancel prefix tasks and release warm players, preserving pending
neighbour resolution and resolved posters; recovery needs the higher buffer threshold. A fully
buffered finite tail can recover below that threshold, but never during a stall.

Throughput and request time to response headers come from the existing upstream
URLSession delegate for both playback and speculative transfers. Throughput is **per connection**,
a conservative estimate rather than aggregate link capacity. Receive timing
excludes deliberate streaming backpressure. Samples smaller than 32 KiB or 10 ms
are excluded from throughput to avoid tiny manifest/tail bursts inflating capacity;
The first valid TTFB sample is ignored to avoid cold DNS/TLS bias; subsequent headers update latency. Cache hits do not update throughput. Readiness and
dwell update on actual sequential forward activations, excluding the initial item,
backward revisits and jumps. No network-type, radio, Low Data Mode or Wi-Fi rule exists.

`prefetchDecision` is Benchmark SPI and is recorded **only when the applied plan
changes and an HMJSONLFileSink is attached**. Partner sinks, including Mux, receive
no policy snapshots. Inputs/Plan JSON encoding and event serialization run on the
JSONL writer queue. Without a benchmark sink no decision event is built or encoded.
Evaluation uses existing buffer ticks, at most four times/sec unless safety changes
require an immediate decision. Stable plans do not assign observable state, reapply
pool configuration, or restart transfers. A changed cap updates prepared neighbours
only when the value changes; the current item's cap is set once at activation,
then lifted under the existing startup-window rules. A changed budget can extend a
completed prefix. `transferSample` remains separate from byte accounting.

The analyzer adds actual forward-arrival `ready_hit_rate`, `plan_changes`,
`average_budget_bytes` and `policy_decisions`. Budget average is change-weighted,
including paused plans; it is not bytes downloaded. Configuration fingerprints
include adaptive mode, every threshold, resolution horizon and concurrency cap.

## Default thresholds and benchmark knobs

All thresholds are mutable on `configuration.adaptiveThresholds` under `@_spi(Benchmark) import HotMicPlayer`. They are experimental tuning, excluded from partner API. Grid knobs use
numeric values, including `adaptive: 0`/`1`, `prefetch-concurrency` (0–4), and
`resolve-ahead` (0–32), and `cached-start-bytes` (tier-2 readiness floor). Direct arguments/environment use the same names:
`--hm-adaptive 0`, `HM_ADAPTIVE=0`. Existing knobs still override strategy presets.

| Property | Default | Grid knob |
| --- | --- | --- |
| `slowBytesPerSecond` | 500_000 | `adaptive-slow-bytes-per-second` |
| `fastBytesPerSecond` | 2_000_000 | `adaptive-fast-bytes-per-second` |
| `speedHysteresisFraction` | 0.2 | `adaptive-speed-hysteresis-fraction` |
| `highLatencySeconds` | 0.4 | `adaptive-high-latency-seconds` |
| `lowHitRate` | 0.7 | `adaptive-low-hit-rate` |
| `bingeDwellSeconds` | 2 | `adaptive-binge-dwell-seconds` |
| `longDwellSeconds` | 8 | `adaptive-long-dwell-seconds` |
| `safetyBufferSeconds` | 1.5 | `adaptive-safety-buffer-seconds` |
| `recoveryBufferSeconds` | 3 | `adaptive-recovery-buffer-seconds` |
| `slowBudgetFraction` | 0.25 | `adaptive-slow-budget-fraction` |
| `mediumBudgetFraction` | 0.5 | `adaptive-medium-budget-fraction` |
| `bingeBudgetMultiplier` | 1.5 | `adaptive-binge-budget-multiplier` |
| `longDwellBudgetMultiplier` | 1.5 | `adaptive-long-dwell-budget-multiplier` |
| `longDwellDelayFraction` | 0.5 | `adaptive-long-dwell-delay-fraction` |
| `maximumDelaySeconds` | 6 | `adaptive-maximum-delay-seconds` |
| `slowAhead` | 1 | `adaptive-slow-ahead` |
| `mediumAhead` | 3 | `adaptive-medium-ahead` |
| `slowBitRate` | 600_000 | `adaptive-slow-bit-rate` |
| `mediumBitRate` | 1_000_000 | `adaptive-medium-bit-rate` |
| `fastBitRate` | 3_000_000 | `adaptive-fast-bit-rate` |
| `ewmaAlpha` | 0.25 | `adaptive-ewma-alpha` |

Speed tiers retain their previous state within ±20% of each throughput boundary.
Slow exits at 600000 B/s; medium enters slow below 400000. Medium enters fast at
2400000 B/s; fast exits below 1600000. The band is configurable from 0 to 1.
A direct jump can cross both boundaries. The high-latency override uses the same
hysteresis fraction independently: with an existing plan it enters above **0.48s**
and exits at or below **0.32s**. With no previous plan it uses **0.4s**. The first
valid TTFB sample remains excluded. A slow throughput tier does not by itself
latch the latency override.

Slow throughput or high latency uses at most 128 KiB (and 25% of the app budget), one ahead, no behind,
and a 600 kbps starting rendition. Unknown/medium uses 50%, three ahead and
1 Mbps; fast uses the full app window/budget and a desired 3 Mbps ceiling, still
capped by the app (default 1.6 Mbps). Slow concurrency is at most one; faster
conditions can use the configured cap (default one). Binge misses multiply the
budget by 1.5, bounded to the app maximum. Long dwell also deepens it by 1.5 and
waits half the estimated dwell, at most six seconds. Default safety/recovery is
1.5/3 seconds; the existing app `threshold` provides half/full floors respectively.

Limits: prefix seconds are MP4 duration/size estimates or HLS segment selections,
not a decoded-media guarantee. Native AVPlayer may read beyond its requested
forward buffer and is governed by the app player/buffer settings, independently
of explicit disk-prefix budgets. A cached prefix records availability, not proof
that it contains a complete independently decodable frame. Far references resolve metadata without a media request or format probe. Auto-format
probing (HEAD, bounded two-byte fallback if needed) waits until an entry enters a media tier.
The cache remains immutable VOD; existing advanced-HLS/auth/DRM/live limitations
apply. Simulator shaping is shared origin payload pacing, not radio/TLS/netem.
Validate threshold changes against a physical-device benchmark grid.

See [benchmark setup](BENCHMARKING.md) for reproducible simulator checks and
physical-device measurement workflows.

## Device performance round 1: playback priority

Until the active item displays its first frame, and during a stall, explicit
prefix transfers and warm-player responses are cancelled. The active request
never waits for a speculative prefix. A known resource size (including a two-byte
AVPlayer probe) no longer changes a missing range into a fully buffered 512 KiB
response: cached bytes are sent first, then the missing suffix streams as it
arrives. This applies to MP4, HLS init resources and HLS segments alike.

Slow-link speculation is limited to +1 and a 128 KiB head, including binge misses.
The starting bitrate is applied before the native item is attached, so the first
HLS selection uses the same cap as the warm path; the master remains intact for
later ABR. A ceiling is advisory to AVPlayer, not a bandwidth guarantee.

The nearest warm decoder can start as soon as the current frame has displayed
and one second is buffered on an unmeasured/healthy link, before bulk-prefix
recovery. Its native buffer target is one second, bounded by the app warm-buffer
limit. Explicit prefetch excludes warm-player items and waits for their frames;
it cannot duplicate the next head or compete with its preroll. A prerolled
activation keeps that target until the startup window ends, avoiding an immediate
1-to-10-second target jump. viewStart records warm-start time and preroll completion.
With three S3 players the window is next/current/previous; four also prepares +2.
