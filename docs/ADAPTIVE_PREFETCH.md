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
configuration.adaptiveThresholds.slowBytesPerSecond = 400_000
let player = HMPlayer(configuration: configuration)
// Optional: player.prefetchPolicy = PartnerPrefetchPolicy()
```

`HMPrefetchPolicyProviding.decide(_:configuration:)` accepts `HMPrefetchInputs`
and returns `HMPrefetchPlan`. `HMAdaptivePrefetchPolicy` is the stateless default;
`wasPaused` carries hysteresis explicitly. A partner provider receives the same
smoothed measurements. The engine clamps every returned plan and independently
enforces buffer safety. `player.prefetchPlan` exposes the last applied plan.

The readiness tiers are:

1. `warmPlayer`: the nearest next entry is prepared/prerolled in the second player.
2. `cachedBytes`: at least `minimumCachedStartBytes` payload bytes are on disk
   (default 32 KiB, bounded by a positive app per-item prefix budget). This
   excludes tiny native probes; it does not guarantee a complete decoded frame.
3. `resolved`: media URL and poster metadata are resolved, with no ready player or disk prefix.

`resolveAhead` (default 8, bounded to 32) controls the metadata-only horizon.
The cache window follows distance order with forward entries first at equal
distance. Binge misses suppress behind work and focus on +1/+2. The default
hybrid uses two players; explicit benchmark strategies retain their player knobs.
A long dwell delays ready-player and disk work from activation, then uses a deeper
budget. Resolving metadata can continue once the current buffer is safe.
Stalls/unsafe buffers cancel prefix tasks, release warm players and cancel pending
speculative resolutions; recovery needs the higher buffer threshold. A fully
buffered finite tail can recover below that threshold, but never during a stall.

Throughput and request time to response headers come from the existing upstream
URLSession delegate for both playback and speculative transfers. Receive timing
excludes deliberate streaming backpressure. Samples smaller than 32 KiB or 10 ms
are excluded from throughput to avoid tiny manifest/tail bursts inflating capacity;
headers still update latency. Cache hits do not update throughput. Readiness and
dwell update on actual sequential forward activations, excluding the initial item,
backward revisits and jumps. No network-type, radio, Low Data Mode or Wi-Fi rule exists.

Every evaluation emits `prefetchDecision` into the normal analytics stream and
JSONL: complete JSON `inputs` and `plan` properties, `reason`, provider name, and
numeric budget/window/concurrency/bitrate/pause metrics. Evaluation uses the
existing buffer ticks, at most four times/sec unless safety changes require an
immediate decision. Stable plans do not restart transfers. A changed budget can
extend a previously completed prefix. `transferSample` is separate from byte
accounting so measurement events never inflate network totals.

The analyzer adds actual forward-arrival `ready_hit_rate`, `plan_changes`,
`average_budget_bytes` and `policy_decisions`. Budget average is evaluation-weighted,
including paused plans; it is not bytes downloaded. Configuration fingerprints
include adaptive mode, every threshold, resolution horizon and concurrency cap.

## Default thresholds and benchmark knobs

All thresholds are mutable on `configuration.adaptiveThresholds`. Grid knobs use
numeric values, including `adaptive: 0`/`1`, `prefetch-concurrency` (0–4), and
`resolve-ahead` (0–32), and `cached-start-bytes` (tier-2 readiness floor). Direct arguments/environment use the same names:
`--hm-adaptive 0`, `HM_ADAPTIVE=0`. Existing knobs still override strategy presets.

| Property | Default | Grid knob |
| --- | --- | --- |
| `slowBytesPerSecond` | 500_000 | `adaptive-slow-bytes-per-second` |
| `fastBytesPerSecond` | 2_000_000 | `adaptive-fast-bytes-per-second` |
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
| `slowAhead` | 2 | `adaptive-slow-ahead` |
| `mediumAhead` | 3 | `adaptive-medium-ahead` |
| `slowBitRate` | 600_000 | `adaptive-slow-bit-rate` |
| `mediumBitRate` | 1_000_000 | `adaptive-medium-bit-rate` |
| `fastBitRate` | 3_000_000 | `adaptive-fast-bit-rate` |
| `ewmaAlpha` | 0.25 | `adaptive-ewma-alpha` |

Slow throughput or high latency uses 25% of the app budget, two ahead, no behind,
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
Default thresholds still require the teammate's physical-device benchmark grid.

See [adaptive simulator evidence](ADAPTIVE_SIMULATOR_SMOKE.md) and
[benchmark setup](BENCHMARKING.md) for the reproducible smoke flow.
