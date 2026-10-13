# Performance interpretation and provenance

The [root README](../README.md#requirements-and-performance) inventories historical runs, supplied observations, unsuccessful/reverted work and pending physical-device comparisons. Current defaults are HLS in the examples, two players, fixed 3/1, four seconds/8 MiB per entry, adaptive off and known-target lift. Existing historical configurations may override them; a configuration or grid on disk does not prove it ran.

The benchmark runner, grids, encoding/origin tooling, result receivers/analyzers and Device Farm workflow are maintained separately from this public SDK. They are not required to build the SDK, use the partner examples or run the [public UI regressions](../Sample/TestSupport/README.md). The SDK retains experimental Benchmark SPI analytics and JSONL dispatch for an external lab; these are excluded from the stable partner API.

## Comparable workloads

Use identical source content, build, device/OS, network shape, cache state, player count, budget and dwell/script conditions. Physical iPhone 16 Pro/iPhone 11 comparisons require at least three matched repeats per cell and remain pending. Programmatic page moves use settled/commit clocks; known-target touch swipes may activate at lift. Do not infer a touch-lift benefit from a programmatic workload or combine these clocks. Include normal dwell, one-second swipes, pause-bursts, back navigation and ranked playlist edits.

Report attempted/started/never-started views and start coverage alongside first-video and swipe distributions. First-frame and first moving playback are different observations. Report stalls, network/unused bytes, cache reuse, continuous peak memory/player count and settling/animation. Missing starts must remain visible, rather than being treated as zero latency. Short dwell truncates startup observation.

## Metrics and limits

Report p50/p90/p99 TTFF, fraction of **all activations** at or below 100ms, separate first-video and swipe p50/p90/p99 and fractions at or below 100/150ms, censored activations, first-10s stalls,
network/cache/wasted bytes, errors, max live players and sampled memory.
Quantiles include displayed frames only; censored views are always shown.
Analysis rejects malformed/truncated JSONL, missing/duplicate runEnd, unmatched
frames/views, missing startup summaries and inconsistent monotonic timing.
`--allow-incomplete` is diagnostic only, never smoke proof/headline results.

Headers record the full serialized configuration and SHA256 fingerprint, run/
format/network/script labels, device/OS/build SHA, simulator flag and grid cell/
cache-state dimensions. Startup summaries cover up to ten wall-clock seconds
from the request, or until leaving; a binge view does not claim ten seconds of
observation. Network bytes are received media payload, excluding protocol/TLS
headers, manifest-fetch/poster/result traffic and OS network totals. Cache bytes
include probes/repeated reads. Wasted prefetch means bytes never supplied to
activated playback, not pixels never watched. See ARCHITECTURE for detector
refresh-period uncertainty and immutable-VOD limits.

Simulator tables must be labeled **“simulator smoke run — not benchmark
numbers”**. Physical iPhone/Device Farm validation remains necessary for display
latency, layer swaps, RAM/decoder/thermal behavior, actual network profiles,
HTTPS/HTTP2, signing/re-signing/installation and unattended result delivery.


Cache identity includes every query parameter by default. Hosts may configure `volatileSigningQueryParameters` with explicit signing names; unrelated variants stay distinct. Playlists have a three-second memory TTL and do not persist across relaunch. Clear caches only after prior controllers and requests have drained.

The public Sample's Release configuration supplies no ATS exception. The SDK probes its numeric loopback endpoint and falls back to direct media URLs when host policy blocks it; partners need no ATS exception for the SDK.

## Ready-layer display continuity

The surface observes display boundaries while a warm incoming page is visible
during the swipe animation. If the same item's layer remains attached, opaque,
ready and visible across the preceding and current boundaries, it can report
that frame on the first boundary after page commit. Previously the detector
started observing only after activation propagated through SwiftUI, then waited
for two more boundaries. Offscreen, detached, recycled, hidden and unready layers
clear continuity. Inactive observation is limited to the immediate ±1 pages;
other attached cells do not run display links. The hosted layer must exactly
match the surface bounds. Resume seeks hide the old frame, invalidate continuity
at both seek start and completion, and require fresh display boundaries after
completion. No pre-seek frame or preroll timestamp is reported as TTFF: the request clock is
the final-target lift clock for known touch destinations, or the settled callback for programmatic/unknown targets; firstFrame uses the current post-commit
display boundary. HMPlayerNode still validates activation identity, native item
status and layer readiness. Cold frames retain the two-boundary requirement.

The analyzer retains aggregate TTFF fields in CSV for compatibility. Its printed
table uses separate first-video and swipe fields, with runs, censor counts,
stalls, bytes and sampled memory. Each threshold percentage divides by all
activations of that kind, including views that never displayed a frame. The
first-video population is one play activation per grid repeat; three repeats
therefore provide only three first-video observations per cell.
