# Prefetch and performance

The default is fixed bounded preparation. Opt into adaptation when your own matched workloads justify it.

## Defaults and units

`.default`, the public initializer and the no-argument player agree: two native content players; fixed three ahead / one behind; target four media seconds with an 8 × 1024 × 1024-byte speculative payload cap per entry; 128,000,000-byte global disk cap; serial explicit prefixes; eight-entry metadata horizon; adaptive off. HLS is an item/resolver choice, and the examples supply real HLS URLs. MP4 remains supported.

```swift
import HotMicPlayer
var config = HMPlayerConfiguration()
config.prefetch = HMPrefetchPolicy(ahead: 3, behind: 1,
    bytesPerItem: 8 * 1024 * 1024, secondsPerItem: 4)
config.adaptive = false
config.activationTrigger = .lift
let player = HMPlayer(configuration: config)
let url = URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!
player.replaceAll([.init(id: "hls-1", url: url, format: .hls)])
```

The startup setting is 1,600,000 **bits/second**, requested for the existing four-second startup window. It is AVPlayer's desired bandwidth preference, not a hard native rate or exact-rendition lock. The four-second speculative duration target is independent of that startup window. MP4 duration selection is estimated from file size and a duration hint. HLS includes complete segments and their init/key/audio dependencies, with all manifest/audio/video payload counted under one cap; an oversized segment or short asset can make four seconds unattainable. Detailed telemetry records the achieved duration and reason. HEAD rejection (403/405/501) or unknown length falls back to bounded, budgeted GET metadata probes and reuses fetched bytes. Manifests are bounded to 512 KiB and the remaining entry budget. Unsupported speculative ranges or an insufficient budget can still yield no explicit prefix; activation can still use native playback.

## Current, next and the data window

```text
N-1 bytes       N current player       N+1 prepared player       N+2/N+3 bytes
                 first priority        bounded immediate next    serial farther work
```

Fixed mode prepares immediate next independently of current's first frame and unknown dwell. Current origin reads lead. Immediate next may progress during cold startup; after a true rebuffer following moving playback, speculative progress waits for recovery. Farther tasks park between bounded chunks without losing their token or useful bytes. A changed immediate next wins the next chunk slot, even when current is healthy. Current requests preempt a warm native owner of that exact resource URL immediately. Eligible prefixes and metadata probes only preempt parked native holders and reuse received bytes; parked means budget, priority or activation waits, or sustained client-send backpressure. Healthy native reads finish and supply the prefix from cache, and explicit joins remain chunk-bounded.

At committed lift, the prepared node is activated once and the outgoing node is recycled for the new next. The previous entry keeps bytes without a decoder. Demoted in-window work survives; entries outside the window lose routes, pins and requests. Shared disk ownership is recorded on cache hits as well as writes so removing one entry cannot erase a surviving entry's shared resource. Global LRU capacity applies even to pinned entries. Native and prefix requests coalesce in either direction, then consume cached bytes instead of requesting the same head again.

Warm-native and explicit speculative network payload share the byte cap in the loopback transport. Activated playback has independent native buffering demands; preferredForwardBufferDuration is not an exact download duration. Direct fallback is deferred for an inactive prepared node until activation. HLS prefetch chooses the highest advertised bandwidth under the startup preference (or the lowest if none fits); AVPlayer can choose a different rendition. Immutable VOD/master playlists remain in memory while retained, while live/EVENT entries use playlistTTL; zero disables playlist memory.

## Lift and settled activation

The paging bridge forwards UIKit's callback before reading its final aligned target ID. A known target activates at lift. A missing, fractional or stale target waits for a settled fallback; there is no velocity guess or transient scrollPosition activation. Cancelled/return-to-origin drags retain current. Fullscreen, rotation/resize, insets, programmatic moves and structural edits keep their existing safeguards. An early current-ID change does not force another scroll animation.

Touch, lift, activation, first-frame and settle clocks are separate. A target-versus-settle mismatch is recorded as unsuccessful activation and must be investigated; a later correction is not a successful lift result. Use `.settle` when you deliberately want all activation to wait:

```swift
var config = HMPlayerConfiguration()
config.activationTrigger = .settle
```

## Alternate presets and opt-in adaptation

`.instantStart` requests 900,000 bits/s for three startup seconds with an eight-second steady buffer; `.highQuality` requests unrestricted startup and a 20-second steady buffer. Both retain two players and the same fixed data window. `.off` disables upcoming native/media preparation (current playback continues). `.nextOnly`, `.balanced` and `.aggressive` are deliberate alternate windows, not measured universal improvements.

```swift
var config = HMPlayerConfiguration()
config.adaptive = true
let player = HMPlayer(configuration: config)
```

``HMAdaptivePrefetchPolicy`` uses smoothed per-connection throughput, header latency, readiness, dwell and buffer health, with hysteresis and app limits. Unknown conditions use its intermediate plan. It does not infer performance from Wi-Fi/cellular labels. Custom ``HMPrefetchPolicyProviding`` implementations are Sendable, synchronous and must be cheap; fixed mode bypasses them. Adaptive mode retains buffer safety and its measured-dwell next-head exception; it is deliberately distinct from independent fixed bootstrap.

| Knob | Limits |
| --- | --- |
| poolSize | 1–4 slots; default 2 |
| prefetch.ahead / behind | 0–8 each |
| prefetch.bytesPerItem | 0–8 MiB |
| prefetch.secondsPerItem | Optional target, always byte-bounded |
| maxPrefetchConcurrency | 0 disables prefixes; execution is serial in this implementation |
| resolveAhead | 0–32 URL/poster entries, default 8 |
| cacheCapacityBytes | Global disk payload cap; zero disables explicit disk work |
| playlistTTL | Mutable HLS playlist freshness in seconds, default 30 |

## Evidence and limitations

The [root README](https://github.com/hotmic-wp/hotmic-player-ios#requirements-and-performance) inventories work actually run, supplied historical observations, reverted experiments and pending device gates. The [performance interpretation guide](https://github.com/hotmic-wp/hotmic-player-ios/blob/main/docs/BENCHMARKING.md) describes comparable workloads; the [public regression harness](https://github.com/hotmic-wp/hotmic-player-ios/blob/main/Sample/TestSupport/README.md) needs no private checkout. Simulator runs prove behavior, not physical-device speed. Compare attempted/started/never-started views, first versus swipe p50/p90, first frame versus first moving playback, stalls, network/unused bytes, cache reuse, memory/player count and settling. First-frame percentiles count only started views.

Readiness distinguishes resolving, cold, resolved, cachedBytes and warmPlayer. Cached bytes do not prove a decoded frame. Player-event TTFF is seconds; analytics ttff_ms is milliseconds. Detailed JSONL policy/gesture/transfer telemetry remains Benchmark SPI and flows through the analytics hub; partner sink events remain separate from policy snapshots.

Use immutable VOD URLs. Live playback, DRM, variable-substitution HLS and automatic authenticated-origin renewal remain outside the supported contract. Signing normalization is explicit and does not invent new signed child URLs; keep origin URLs valid for the active visit. Connect/backend changes remain a separate adapter phase.

Speculative payload accounting includes loopback manifest/audio/video/init bodies and warm native requests, including revisits that are currently inactive. It excludes HTTP/TLS overhead, resolver format probes, posters and separate sidecar-caption fetches. The budget is not a bound on all network traffic or activated native playback.

First moving playback is observed from positive media-clock progress on existing native ticks and logged separately from first frame and native control status. Explicit seek/loop decode catch-up with already-playable buffered media receives at most 150 ms of grace, followed by a waiting-state recheck; prolonged waits and empty-buffer waits after playback began count as rebuffering. This observation is sampled timing, not a frame-exact moving-pixel detector.
