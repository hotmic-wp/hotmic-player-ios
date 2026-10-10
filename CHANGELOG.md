# Changelog

## Unreleased

- Add optional `HMSocialPlayerView`, `HMSocialOverlay` and a UIKit host for themeable social playback on public hooks, with standalone metadata, preview, Fire burst, progress, pause and comment-sheet components. Extend the existing action rail without changing its original initializer.
- Add backend-independent social data/actions, an `HMEngagement` adapter, native sharing helper, interactive squeezeback, ad suppression, caption/mute controls, safe sidecar placement and host replacement sheets. Extend `HMTheme` with custom images, rail spacing and motion timing.
- Add a generic Partner demo with offline mixed-orientation media, fake engagement, persistent navigation and kit/custom UI switching, plus a ready-made overlay DocC guide and opt-in benchmark overlay cells.

- Preserve `.all` as the original chat, timed reaction and poll capability mask; opt into `.toggleReaction` and `.loadComments` explicitly. Add `HMEngagement.setReaction(_:reacted:)` for add-only double taps and retain the latest rapid-tap intent with serialized follow-up requests.
- Treat cancelled engagement loads/reactions silently, preserve known counts when pages omit totals, and bound cached source comments to 512 while retaining live refresh updates. Reset social preview selection on item changes, retain drafts edited during posting, and reject stale example paging cursors.

- Add optional per-item reaction membership/counts, optimistic toggle with rollback, independent comment paging/counts and rotating preview selection on `HMEngagement`. Existing clock-indexed VOD chat and stream reactions retain their behavior; source methods have compatibility defaults.
- Add a copyable custom engagement backend example and a shared social Sample UI switching between an in-memory host backend and a fake Connect client.

- Add HLS legible track selection and per-language MP4 WebVTT sidecars, system-following CC preferences, bounded next-item caption prefetch, MediaAccessibility styling and caption-safe overlay regions/insets.
- Observe audio interruptions, removed output routes, application lifecycle and media services resets; preserve host audio-session ownership and expose lifecycle events. Add explicit background-audio policy.
- Add title/state/time/mute/CC accessibility values, core custom actions and a ten-second adjustable position shared with the UI scrubber (previously 5% steps). Add a generated local captions/audio Sample and DocC guides. `HMPlayerEvent` gains `audioSession` and `captionsChanged`; update exhaustive host switches.

- Add visit-scoped `HMAdBreakProvider` for host SDK and URL pre-rolls, safe-area letterboxing, `adState`/`adProgress`, host playback permission, skip/cancellation, bounded deadlines and protected content prefetch. Add the offline Ads lab and ad/no-fill benchmark scenarios.
- **Source compatibility:** `HMPlayerEvent` and `HMPlaybackEvent.Kind` gain ad lifecycle cases. Update exhaustive host switches when upgrading; use `@unknown default` for future SDK enum cases. Ad phase is `.playing(kind:)`; observe `HMPlayer.adProgress` separately from lifecycle events.

- **Behavior change:** video surfaces now enable single-tap play/pause by default and expose a localized Video accessibility element with Play/Pause actions. Hosts can override the tap callback; Fire is opt-in.
- Fullscreen defaults to independent zero-inset layout with optional fullscreen layout hooks, recomputed overlay exclusions, and no inherited inline reservations.
- Add UIKit video-frame change callbacks and explicit full-bleed safe-area opt-in. Preserve UIKit's safe-area default and HotMicPlayerUI's locale compact names.
- Compact social counts roll rounded thousands/millions up to the next suffix and support billions.

- Correct unconstrained inline sizing (`aspectRatio: nil`) so squeeze targets use stable host bounds.
- Add rendering-only content insets and interactive squeeze targets for feed, inline and fullscreen, preserving native playback identity.
- Add host tap/Fire hooks, automatic and explicit hit-area exclusions, free overlay rectangles, ad gesture gating, VoiceOver actions and Reduce Motion support.
- Add locale-aware `HMCountFormatter` and a public-API social layout Sample plus “Building your own overlay” DocC guide.


- Harden fullscreen for portrait-only hosts, open sheets and duplicate presenters; follow rotation from a portrait feed, preserve quick swipes after exit, and resume failed-item skipping on exit.
- Reuse partner overlays in fullscreen (including a UIKit `fullscreenOverlay:` initializer), pause detached inline views, and preblur bounded decoded/poster backdrops without consuming startup measurement frames. Fix rotated still orientation and fallback video-output retention.
- Add per-item aspect hints and warm-track/decoded presentation-size detection, exposed on playback snapshots. **Behavior change:** the default feed policy is now `.automatic`; landscape and other mismatched media letterbox instead of cropping to the vertical container. Matching vertical media still fills, and explicit `gravity:` calls retain their behavior.
- Add configuration and per-item presentation policies (`automatic`, `fill`, `fit`, `fitWithBlurredBackdrop`, `fitWithColor`), configurable tolerance/color, and page-coordinate `videoFrame` in overlay snapshots. Blurred backdrops use a poster or a small still from the existing decoded output, with no extra decode.
- Add `enterFullscreen()` / `exitFullscreen()`, observable `isFullscreen` and opt-in landscape device rotation. Fullscreen reuses the current node/layer without seeking, buffering again or resetting TTFF, and disables feed paging until exit.
- Add non-paging `HMPlayerView` (SwiftUI, default inline 16:9) and `HMPlayerViewController` (UIKit, host-sized), sharing HMPlayer's cache, prefetch, loops, mute, seek and playlist navigation.
- Add a mixed MP4/HLS orientation Sample, horizontal benchmark grid/inline scenario, orientation manifests and per-orientation analysis. Document host orientation setup and the still-poster backdrop behavior.

## 1.0.0-rc.4

- Move the canonical public player repository to [hotmic-wp/hotmic-player-ios](https://github.com/hotmic-wp/hotmic-player-ios) and update installation and documentation links. Rename the optional HotMicCore adapter package to [HotMicPlayerConnect](https://github.com/hotmic-wp/hotmic-player-connect-ios), with `HotMicItemResolver`, `HotMicPlaylistSource` and `HotMicInteractionSource`.
- A non-identical `replaceAll` that retains the selected ID and canonical source preserves playback and overlapping pool assignments without emitting `currentItemChanged`. Identical replacements also preserve failures, the paging cursor, resume positions and `loadError`.
- Keep terminal, network and resolution failure memory across metadata-only or signing-only refreshes; `jump(toID:)` explicitly retries a failed entry, including the selected one. Reset saved resume positions on source changes.
- Use the cache's canonical URL identity for playback and prefetch, stripping only configured volatile signing query parameters. Count native assignment releases independently of seeks; add a public `HMPlaylistChange` initializer.
- Empty `reconcile` lists are no-ops. History-only refreshes go idle without replaying history. Finish-once removal falls back to immediate advance for failed, failure-idle or already-ended current entries, including failures during the finishing visit.
- Add ranked-feed `reconcile(_:)`, observable Sendable/Equatable `lastPlaylistChange`, and `removedCurrentPolicy` with default immediate advance or finish-once removal, including normal swipe-away behavior.
- Preserve native players and cached bytes across identical and display-only refreshes. Keep overlapping in-flight prefetch work across playlist edits, canceling only entries that leave the window.
- Report decoded inactive prepared entries as `warmPlayer` for upcoming badges; preserve active readiness measurements. Add a ranked-feed Sample toggle and usage documentation.

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
