# HotMicPlayer architecture (0.2.0)

The dependency-free player package defines `HMPlayer`, its VOD engine, `HMVerticalFeedView`, analytics and three partner adapter protocols. A later, separate `HotMicPlayerCore` package will depend on this package and HotMicCore to implement those adapters. There is no Core code here.

## Public contract and atomic playlist edits

`@MainActor @Observable HMPlayer` is the only playback owner. Public value types describe entries, sources, snapshots and events. Native `HMPlayerPool`, `HMPlayerNode`, the cache proxy and video-surface views are internal. Analytics sinks can still attach to native layers through the existing hub contract.

`HMPlaylistState` computes edits and validates the full resulting list before committing. The current item is tracked by stable ID and mapped to its new index when earlier entries disappear. Upcoming/insert/append/removal of other entries preserve the assigned active node, `AVPlayerItem`, layer, activation and media clock. `replaceAll` explicitly ends the old activation and resets resume positions. Removing current selects the next surviving entry after its old index, then the previous survivor; no survivors means idle.

Every accepted edit increments a playlist revision. The scroll bridge cancels animation/deceleration and anchors to the last settled current entry's new index; callbacks captured from an earlier revision cannot activate a stale page. Removing current anchors to its survivor. SwiftUI's quiet-period fallback also rechecks revision and item ID. This defines the result even when several edits arrive in one run-loop turn during a drag.

An edit invalidates pending page fetches; `replaceAll` also resets the cursor. Source pages use the exact append validation and refresh path while committing under their own generation. Late pages from an old source/list cannot append. Low-water paging uses the configurable number of entries after current.

## Hybrid two-player engine and prefetch

Default S3 has one active native player and one prepared next player, plus an independent bounded data window. S0 has one direct player, S1 adds data prefetch, and S2 preserves the warm-pool comparison. No adaptive policy is implemented in this milestone.

The resolution window is current plus configured data/warm offsets. `HMResolutionStore` coalesces pending tasks for an immutable entry, caches completed metadata for the player session, and cancels unfinished resolution when the entry leaves the window. Current resolution uses user-initiated priority; upcoming resolution uses utility priority. Direct extensionless `.auto` URLs use a HEAD response to distinguish HLS from MP4. Explicit formats and known extensions avoid that request.

Media prefetch is gated on current buffer safety, with hysteresis around the threshold. Resolution runs independently of that gate. A window edit cancels obsolete speculative work immediately, releases removed routes/requests and trims the displaced next player. A safe current buffer allows the new next assignment to prepare immediately. Otherwise it waits for safety so speculative work cannot queue ahead of the current item. Prefetch identity changes with the configuration, order and resolved URLs; no-op buffer ticks do not restart tasks.

## Loopback transport and cache ownership

One `NWListener` serves loopback HTTP routes for MP4 and HLS. The transport actor owns requests, streams and payloads; a locked small snapshot exposes only healthy port, route and cache-size state to the main actor. The listener port is published only after a HEAD health request proves host ATS access. Failed startup leaves direct playback available. A playback-time loopback failure has a direct fallback retaining the activation clock.

Current origin requests use high priority. Speculative requests use low priority and a separate URLSession connection pool. Connection caps are eight per host. Fetcher state (`pending`, `task`, `response`, counters and completion) is lock protected. Streamed responses suspend upstream work while the player applies backpressure. URLSession's request deadline is extended for those streams; an explicit 20-second inactivity watchdog runs only when upstream work is permitted. A deliberately paused, full-buffer player therefore does not time out. Cancellation and watchdog expiry settle the continuation once.

A streamed origin response emits one transfer event with its total received bytes, including partially received failed responses, rather than one event per chunk. Bounded range fetches emit one event per upstream response. Cache reads emit their delivered cache bytes. Media bytes are stored in bounded 512 KiB ranges, and the disk LRU cap is hard even when the window exceeds it. Cache identity preserves query parameters unless an app explicitly declares particular signing parameter names volatile.

The window retains current routes while upcoming routes are pruned. Removed playlist media owners are released. Equal root URLs and known shared HLS child resources are preserved for remaining owners. Resources are pinned only as a preference within the hard cap. HLS playlists never persist to disk: they are cached in memory with configurable TTL (default 30 seconds). Route/waste retention scans run on window changes and task completion, not after each streamed chunk. Wasted bytes compare speculative range unions with ranges delivered to activated playback; warm-only delivery is not counted as watched.

## Overlay-by-clock model and interaction lifecycle

An overlay is a pure rendering function of `(media clock, timeline)`. Chat queries a time window; reactions replay at their authored offsets; density and clustered markers are precomputed. Seeking changes the media clock and therefore rewinds all overlay layers consistently. A tick changes progress and the density mask, without rebuilding the density path or scanning every event.

`HMInteractionSource.timeline(for:)` supplies this clock-indexed data without opening a session. Synchronous lifecycle hooks own current and next only. `willBecomeNext` prepares next, `didBecomeCurrent` promotes current, and `didLeave` closes entries outside both roles. Promotion keeps an already-open next session. Hiding or tearing down closes both. Optional send-chat/reaction/vote actions belong to the host adapter; default implementations throw unsupported. `HMMockInteractionSource` wraps deterministic `HMMockTimeline` for the demo.

## Events, Observation and measurement

Each `HMPlayer.events` access creates an independent ordered AsyncStream with a 256-event newest buffer. Streams finish at teardown or finishRun; task cancellation removes their continuations. Observation exposes list/current/paging state, last event and snapshots. Player notifications translate native readiness/first-frame/stall/error telemetry; analytics continues to fan out through the existing hub/sink contract.

Readiness (`cold`, `cachedBytes`, `warmPlayer`) is recorded at activation. TTFF runs from the request clock to a visible display-link boundary after the layer was ready and crossed a display boundary. It estimates presentation to about one refresh period. `firstFrame` carries seconds in the public event stream and milliseconds in analytics. Benchmark startup summaries, memory/allocation metrics, runEnd and JSONL flushing remain available.

## Supported scope and remaining coverage

Immutable VOD, MP4 and HLS, iOS 17+ and zero package dependencies are the partner contract. Snapshot live/DVR fields remain for telemetry compatibility but do not broaden that contract. Live, LL-HLS, DRM, authenticated origins, signed-playlist refresh, HLS byte-range/alternate-audio coverage and concurrent active controllers sharing a disk directory are outside supported coverage. Physical-device decoder, memory, thermal and audible continuity still require device validation. Poster URLs are supported; generating a poster from the first frame is deferred.
