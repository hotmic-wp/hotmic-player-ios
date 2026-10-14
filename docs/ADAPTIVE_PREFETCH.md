# Measured adaptive prefetch

`HMPlayerConfiguration.adaptive` defaults to `false`; this article describes explicit opt-in adaptation. `prefetch.ahead`, `behind`,
`bytesPerItem`, optional `secondsPerItem`, `cacheCapacityBytes`, `poolSize`,
`maxPrefetchConcurrency` and startup/steady bitrate ceilings are app limits.
The policy only reduces them. Fixed mode uses independent immediate-next bootstrap and fixed budgets; custom providers are bypassed.
Zero bitrate means uncapped; zero cache capacity prevents explicit disk prefetch.

```swift
var configuration = HMPlayerConfiguration(adaptive: true)
configuration.prefetch = HMPrefetchPolicy(ahead: 3, behind: 1, bytesPerItem: 8 * 1024 * 1024, secondsPerItem: 4)
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
Stalls/unsafe buffers cancel prefix tasks, preserving pending neighbour resolution and
resolved posters. Startup urgency retains existing warm players without creating new ones;
bulk recovery needs the higher buffer threshold. A fully
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

All thresholds are mutable on `configuration.adaptiveThresholds` under `@_spi(Benchmark) import HotMicPlayer`. They are experimental tuning, excluded from partner API. External lab parameters may use
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

See [performance interpretation](BENCHMARKING.md) and the [public regression harness](../Sample/TestSupportTools/README.md) for reproducible simulator checks and
physical-device measurement workflows.

## Playback priority and independent fixed bootstrap

The fixed default admits a bounded immediate-next head during initial/unknown-dwell startup, before current's first frame. Current reads lead; next is admitted, then farther work progresses serially. A true rebuffer after moving playback parks speculation until recovery. A changed next entry takes the next bounded chunk slot. Surviving tasks retain their tokens and cached progress while parked; outside-window work is cancelled. Shared native/prefix resource reads coalesce in both directions. A current read preempts a warm native owner of that same resource URL and reuses received bytes, preventing a parked-owner deadlock.

Adaptive opt-in keeps its measured-dwell next-head admission and buffer safety, which differ deliberately from fixed bootstrap. On a slower measured tier, the native next player waits for its explicit head; at a fast tier it may join a head only once it is actually running. Issued/queued/running state is distinct, including the interval before actor commands execute. Prefetch rendition selection is a heuristic under AVPlayer's desired bandwidth preference, not an exact lock.

The two content players alternate current/next; previous retains bytes without a decoder. Warm-native and explicit speculative payload share the per-entry cap in loopback. Activated playback is separate and can buffer beyond its requested duration. A range-less warm response can wait until activation; unsupported explicit HEAD/ranges yield no prefix and report failure/outcome rather than blocking native activation. Whole HLS audio/video/init resources, manifest payload and duration-target outcomes are covered by the planner. The root README inventories historical device/simulator evidence and pending matched device comparisons.

Gesture activation defaults to known final target at lift, with settled fallback for missing/stale/fractional targets. No velocity prediction is used. `activationTrigger = .settle` deliberately waits for settling. Gesture clocks and mismatch diagnostics are Benchmark SPI telemetry; simulator coverage does not establish physical-device lift savings.
