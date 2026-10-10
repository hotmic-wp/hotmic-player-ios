# Prefetch and performance

Bound speculative work with app budgets, then let the adaptive policy respond to measured playback.

## Defaults and public knobs

The default uses two native players, a 128,000,000-byte disk cap, serial prefix downloads, and adaptive prefetch. No defaults changed for 1.0.

```swift
var config = HMPlayerConfiguration.default
config.prefetch = HMPrefetchPolicy(ahead: 2, behind: 1, bytesPerItem: 800_000, secondsPerItem: 3)
config.cacheCapacityBytes = 64_000_000
config.maxPrefetchConcurrency = 1
config.resolveAhead = 8
let player = HMPlayer(configuration: config)
```

| Knob | Meaning and limits |
| --- | --- |
| `poolSize` | Native player slots, 1–4. |
| `prefetch.ahead` / `behind` | App maximum data window, each 0–8 entries. |
| `prefetch.bytesPerItem` | Speculative prefix cap, at most 8 MiB per entry. |
| `prefetch.secondsPerItem` | Optional estimate for MP4, whole-segment selection for HLS; still byte-bounded. |
| `cacheCapacityBytes` | Disk media cap; zero disables explicit disk prefetch. |
| `maxPrefetchConcurrency` | Prefix downloads, 0–4; default one. |
| `resolveAhead` | URL/poster-only resolution horizon, 0–32; default eight. |
| `startupPeakBitRate` | Initial bits/second ceiling; zero is uncapped. |
| `playlistTTL` | HLS manifest freshness in memory, seconds; default 30. |
| `adaptive` | False selects fixed app budgets and bypasses custom policy providers. |

`.off`, `.nextOnly`, `.balanced` and `.aggressive` are window presets. `HMPlayerConfiguration.instantStart` favors a smaller starting rendition; `.highQuality` uses an uncapped startup bitrate and a longer buffer. Native AVPlayer reads are separate from speculative prefix budgets and may exceed its requested forward-buffer duration.

## Adaptive decisions

``HMAdaptivePrefetchPolicy`` uses smoothed per-connection throughput, header latency, sequential-arrival readiness, dwell time and current buffer health. It reduces budgets within app limits, prioritizes nearest forward entries, and uses hysteresis to avoid oscillation. Unknown conditions use a conservative intermediate plan. It does not infer a policy from Wi-Fi, cellular or radio type.

Stalls and unsafe buffers cancel speculative prefix work and release warm players; URL/poster resolution continues. Recovery waits for a higher buffer threshold. Evaluation uses existing buffer ticks, at most four times a second unless safety changes require an immediate decision.

Read ``HMPlayer/prefetchPlan`` for the last app-clamped plan, including its reason. Implement ``HMPrefetchPolicyProviding`` for a custom policy; the engine still clamps the result and enforces buffer safety. The protocol is `Sendable` and synchronous: keep `decide` cheap and synchronize any implementation state. Internal default-policy hysteresis state is not public; custom providers own theirs.

## Read the benchmark

The full [benchmark guide](https://github.com/hotmic-wp/hotmic-player-ios/blob/main/docs/BENCHMARKING.md) covers fixture generation, origin setup, device grids and analysis. [Adaptive policy details](https://github.com/hotmic-wp/hotmic-player-ios/blob/main/docs/ADAPTIVE_PREFETCH.md) explain measurement and experimental thresholds.

Compare identical content, device, build, cache state and shaping profile. Use physical devices for tuning; simulator results prove behavior, not device performance. Read TTFF p50/p95 together with stall duration, network bytes and memory; a faster start that wastes bandwidth or stalls later is not a free improvement.

Readiness at activation distinguishes `resolving`, `cold`, `resolved`, `cachedBytes`, and `warmPlayer`. A byte-cache hit is not proof of a decoded frame. Player-event TTFF uses seconds; analytics `ttff_ms` uses milliseconds. Swipe timing starts when a page commits, including subsequent resolution.

The analyzer's `ready_hit_rate` counts actual forward arrivals. `average_budget_bytes` is change-weighted planned budget, including paused plans; it is not downloaded bytes. `plan_changes` measures policy churn. Detailed policy snapshots and JSONL writers are Benchmark SPI, not partner sink events. Device evidence should drive tuning, not assumptions about network labels.

## Supported media

Use immutable MP4 or HLS VOD and versioned URLs. Live playback, DRM, authenticated-origin renewal, advanced HLS byte-range/alternate-audio coverage and multiple active players sharing the same disk directory are outside this release's supported contract. HotMic-backed integration belongs in the separate adapter package.
