# Evaluate HotMicPlayer in one feed screen

## Message to forward

HotMicPlayer gives you a native iOS VOD feed while you keep your media, ranking, backend, UI and ads. The SDK owns playback, bounded current/next preparation, atomic playlist changes and lifecycle. Start with one feed screen and compare your own content and network conditions.

## Why evaluate it

Current/next preparation stays bounded. Stable content IDs support ranked refresh and native-item reuse, along with pagination, reorder and removal. Choose your own backend and UI, or add the optional ready-made overlay; captions, fullscreen, ads and public lifecycle/interaction hooks are available on both paths. URL playback requires no HotMic account. The separate [HotMicPlayerConnect package](https://github.com/hotmic-wp/hotmic-player-connect-ios) targets HotMic content/engagement. Its public main branch requires player `from: "1.1.0-alpha.1"` and cannot resolve a player pinned to `1.0.0`; 1.0.0 compatibility is not validated and adapter delivery is separate. It has its own backend/authentication constraints; per-stream reactions and paged comment history are not yet supplied by the HotMic backend. A host backend can implement the full engagement feature set; see [backend choices](../Sources/HotMicPlayer/HotMicPlayer.docc/EngagementFromYourBackendOrHotMic.md).

This SDK uses the proprietary [All Rights Reserved license](../LICENSE), with integration terms agreed with HotMic.

## Start here

Canonical repository: [hotmic-wp/hotmic-player-ios](https://github.com/hotmic-wp/hotmic-player-ios). The initial 1.0.0 delivery includes the measured defaults, playback/transport corrections and optional diagnostics. Pin `exact: "1.0.0"` for reproducible adoption. Follow the [installation guide](../Sources/HotMicPlayer/HotMicPlayer.docc/PartnerIntegrationGuide.md).

Use iOS 17+, Swift tools 6.0 (the package uses Swift 5 language mode), and Xcode 26.6 for the current CI-supported build/DocC workflow. Package declarations also include tvOS 17/macOS 14; the native feed evaluation described here is iOS, not evidence of full platform UI parity.

| Starter | Use |
| --- | --- |
| [PlayerOnly](../Examples/PlayerOnly) | Your URLs and your UI, core product only |
| [ReadyMadeOverlay](../Examples/ReadyMadeOverlay) | Optional ready-made metadata/actions/comment sheet |
| [CustomOverlay](../Examples/CustomOverlay) | Your overlay composed on public hooks |

Retain one main-actor `HMPlayer` per screen, load `[HMMediaItem]` with unique stable IDs and HLS/MP4 VOD URLs, mount `HMVerticalFeedView` (or inline `HMPlayerView`), and call `teardown()` on permanent dismissal.

| API | Responsibility |
| --- | --- |
| `replaceAll`, `reconcile` | Initial playlist / stable-ID ranked refresh |
| `replaceUpcoming`, `insertNext`, `append`, `remove(ids:)` | Atomic playlist edits |
| `HMPlaylistSource`, `HMItemResolver` | Host pagination and deferred URL resolution |
| `play`, `pause`, `seek`, `next`, `previous`, `jump(toID:)` | Playback/navigation controls |
| `snapshot`, `events`, `isFeedVisible`, `teardown` | Observation and lifecycle |
| `setDiagnostics` | Independent optional aggregate policy |

## Optional diagnostics

Completely off by default. See the [exact enable/disable example and contract](../Sources/HotMicPlayer/HotMicPlayer.docc/OptionalDiagnostics.md): host app key/base URL, default 1% lifetime sampling, 60-second windows/cadence, 8 KiB maximum, one in flight, two-second timeout target and one-attempt/drop behavior. The collector is prepared separately; confirm deployment before enabling a partner pilot. Ordinary starters remain off.

Only coarse configuration, nonunique model/OS/SDK version, counters and fixed timing histograms are included. Identifiers, URLs, raw timestamps/uptime, text/errors, device names, arbitrary properties and viewer credentials are excluded. Encoding and transport run off main; lifecycle/pressure cancel delivery, with no retries, storage or flush. Sampling and dropped windows bias the observed cohort, histogram percentiles are approximate, and records contain no stable viewer identifier to link windows. The server adds tenant and receive time; infrastructure can still observe IP. Review the bundled privacy manifest and host disclosure guidance in the diagnostics article.

## Evidence and limits

The accepted baseline includes 99 meaningful package test cases plus app/example builds, compiled documentation snippets and native simulator regressions. Diagnostics acceptance evidence is local/synthetic and must be reviewed with its source revision; it is not a new physical-device benchmark or a release/deployment claim. Existing physical observations are supplied historical evidence, not guarantees for this candidate or your content. Read the [public performance inventory](../README.md#requirements-and-performance) and [performance interpretation guide](BENCHMARKING.md).

First-frame medians describe only started/displayed views; compare attempted starts and coverage too. Fixed data preparation trades bandwidth for readiness. Continuous rapid swipes remain bandwidth-bound. Matched iPhone 16 Pro/iPhone 11 repeats and settling/animation comparisons remain pending. Simulator timing does not establish physical display latency, thermal behavior or memory cost.

## Pilot acceptance tasks

- Load real HLS VOD with stable IDs; exercise pagination, reorder, reconcile and remove-current policies.
- Cancel swipes, swipe back, pause/resume/seek, dismiss quickly and revisit; check retained native items and cancellation.
- Verify hidden/background/interruption, fullscreen/orientation and host audio ownership, captions and ad boundaries.
- Compare attempted/first-frame/first-moving coverage and stalls alongside network/unused data, memory/player bounds and settling in your host app.
- If explicitly enabled, verify diagnostic sampling, cancellation/drop behavior, wire fields and host privacy disclosures against a confirmed collector endpoint.
