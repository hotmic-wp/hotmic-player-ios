# Changelog

## 1.0.0-rc.3

- Prioritize active playback over prefetch during startup and stalls. Stream cache misses progressively, hold inactive proxy requests without forcing direct fallback, and handle short or oversized origin range replies.
- Start and retain the next item's small head and preroll with buffer hysteresis, bound the warm-frame wait, and reduce adaptive prefetch and HLS startup bitrate on slow links. Preserve existing warm neighbours and the S2 benchmark control.
- Keep incoming warm video layers attached through page transitions. Require a visible frame at a display boundary, guard pending seeks against stale frames, limit inactive display links to neighbouring pages, and preserve native rewind tolerances when recycling players.
- Split benchmark analysis into first-video and swipe TTFF, including the percentage at or below 150 ms. Document the detector and prefetch changes. Simulator smoke validates the flow; physical-device performance remains unverified for this round.

## 1.0.0-rc.2

- Replace private terms in the partner documentation checker with generic patterns and an optional environment denylist. Report file names only and pass the optional denylist from CI. No public API or playback behavior changes.

## 1.0.0-rc.1

- Freeze the public partner contract with no API removals or new renames relative to 0.4.0. Preserve `HMEngagement.update(_:)` as a deprecated alias for `upsertPoll(_:)` (introduced in 0.4.1).
- Add DocC catalogs for both products, partner installation and integration guides, semver policy, and two public-API Examples. Keep Sample as the full demo and benchmark app.
- Synchronize shared moderation on mutation, so engagement queries do not write observed state during SwiftUI rendering. Lazy waveform caches remain outside Observation.
- Persist authoritative `updateReactions(_:forMessage:)` totals in bounded player-owned records across engagement eviction. Document `removeReaction(_:forMessage:count:isOwn:)` as an instance-local delta; use authoritative totals for durable moderation.
- Emit a unified-log error when per-item moderation bounds hide engagement. Include the item ID and recovery lifetime; no message payloads are logged.
- Add macOS PR/main CI for package, Examples and Sample builds, strict DocC, public documentation coverage and the unit suite. No performance defaults changed.

## 0.4.1

- Moderation source updates on `HMEngagement`: `removeMessage(id:)`, `upsertPoll(_:)`, `removePoll(id:)`, message-reaction count removal and stream-reaction removal by ID. `update(_:)` is deprecated and renamed to `upsertPoll(_:)`. Sources with reaction totals should prefer `updateReactions(_:forMessage:)`; reaction removal applies deltas.
- Deletions remove incoming, confirmed-own and pending messages from the rail and waveform, close removed poll cards, and prevent late echoes or action completions from restoring moderated content. Immutable timelines are supported through filtered engagement queries and cached waveform aggregates.
- Player-owned deletion records survive engagement eviction and rebuild. Removed poll IDs ignore later upserts; there is no reinstate API. Records are bounded per item to 4,096 IDs and 256 KiB of ID text; overflow hides engagement for that item rather than forgetting deletions. Records end when the item leaves the playlist or the player tears down.
- Waveform/peak projections rebuild lazily on the next read after event mutations. Chat/reaction queries merge sorted lists without sorting each tick. Source density weighting is kept when its events already exclude deletions; otherwise moderation uses SDK aggregation.
- Sample-only mock moderation controls: launch a Debug build with `--hm-moderation 1` to delete the newest incoming chat, the viewer's last message, the active poll or a peak's stream reactions. Add `--hm-moderation-eviction 1` to narrow the window, show rebuild evidence and send a late poll upsert.

## 0.4.0

- **Engagement data layer** in `HotMicPlayer`: `HMEngagement` (via `player.engagement(for:)`), `HMChatMessage`, `HMPoll`, `HMReactionEcho`, `HMEngagementCapabilities`, `HMEngagementError`. Actions are optimistic, roll back on failure, and land at the item's current media time.
- **`HMInteractionSource` extended compatibly**: `capabilities(for:)` (default `.readOnly`), `polls(for:)` (default none), `react(_:toMessage:for:)` (default unsupported) and `engagementDidLoad(_:)` (default no-op). A 0.3 source compiles unchanged; its action controls stay hidden until it declares capabilities. `HMInteractionError` is now `LocalizedError`.
- **Behavior change:** without an interaction source, the player now uses an empty, read-only source (no timeline events, no polls, no actions) instead of demo data. Demo engagement is opt-in Benchmark SPI: `HMPlayer(interactions: HMMockInteractionSource())`, as the Sample does.
- The viewer's confirmed chat and stream reactions are kept by the engagement itself, so they survive scrubbing even on a timeline that ignores `append`; source echoes with the same ID are de-duplicated. Sources can return the confirmed server event from `sendChat(_ message: HMChatMessage, for:) -> HMTimelineEvent?` and `react(_ reaction: HMTimelineEvent, for:) -> HMTimelineEvent?` (both defaulted, returning nil); it replaces the local event under the server ID, so server reaction updates and echoes find it. `HMChatMessage.clientID`/`rowID` keep list identity stable across the swap.
- Player-created engagements borrow the player's source weakly; engagements and per-item timelines follow the prefetch window (kept anywhere in the playlist once the viewer has acted in them), adopt the resolved item for references, and are cleared on `teardown()`. Items outside the playlist get an inert engagement.
- The engagement scrubber's drag lives in gesture state: a drag cancelled by the feed, a page change or backgrounding never seeks and always ends the player interaction.
- `HMTimelineEvent` gains optional `avatarURL`, `wallTime` and `reactions` (defaulted initializer parameters; source compatible).
- **New product `HotMicPlayerUI`**: the components, `HMTheme`, `HMOverlayLayout`, `HMEngagementLayout`/`HMEngagementContext`, and `HMVerticalFeedView(player:transition:gravity:layout:)`.
- Transient (connectivity) retries are jittered ±25% and only retry the current and next items while the error persists.
- When the last item fails and paging retries are exhausted, the player falls back to the previous item instead of waiting for a page.

## 0.3.1

- Fixed delayed reference activation/rendering for HLS and MP4. Swipe and programmatic-page TTFF start at page commit, preserving comparison with 0.3.0.
- Added `HMReadinessTier.resolving`. **Source compatibility:** exhaustive switches over readiness must handle this new case.
- Added public `failedItemPolicy`: `.skip` by default or `.stay`. Terminal failures skip only after interaction ends; paging gets a chance to supply the next item before previous-item fallback.
- Added read-only `isInteracting`, driven by feed touches and page motion. Host controls outside the feed can use `beginInteraction()` / `endInteraction()`; an unmatched begin expires after 30 seconds.
- Connectivity/timeout errors stay selected and retry with bounded backoff. An owned `NWPathMonitor` clears remembered terminal failures when connectivity returns.
- Added `currentIndex: Int?`, nil when idle. `activeIndex` keeps its compatibility value of zero while idle and must not be used alone to infer a current item.

## 0.3.0

- Add measured adaptive prefetch with replaceable `HMPrefetchPolicyProviding`, clamped `HMPrefetchPlan` and observable applied decisions.
- Measure per-connection throughput/latency, forward readiness and dwell; add speed/latency hysteresis, buffer safety, and a metadata-only resolution horizon.
- Preserve fixed-budget mode and app caps. Keep experimental thresholds and detailed policy telemetry in Benchmark SPI.

## 0.2.0

- Introduce the public `HMPlayer` facade: URL/reference items, five atomic playlist operations, paging, resolution, events, playback snapshots and configuration.
- Add cancellable VOD resolution, bounded paging retries, duplicate-page notices and sample playlist labs.
- Hide engine nodes, player pools, video surfaces, cache transport and benchmark-only controls from ordinary partner imports.
