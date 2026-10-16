# Changelog

## Unreleased

### Ads

- `HMPlayer.isPictureInPictureActive` (host-set), `isExternalPlaybackActive` (follows the external route of the engine playing current content) and `suppressesCompanionAds` report when companion ads must not appear. `HMPlayerEvent.externalPresentationChanged(pictureInPicture:externalPlayback:)` reports each change; update exhaustive switches over `HMPlayerEvent`.

### Engagement data layer

- `HMCommentSelection`: a serializable comment-preview rule (`rule` + `limit`, JSON or query items) shared with backends and other clients. `.recent` is the rule today; `topReactions`, `verifiedOnly` and `pinnedFirst` are reserved names and unknown rules preview as recent. `apply(to:)` is a pure, order-preserving function over any `HMSelectableComment` list; `HMChatMessage` and `HMSocialComment` conform.
- `HMEngagement.audienceCount` / `updateAudienceCount(_:)` and `pinnedComment` / `updatePinnedComment(_:)`: pushed latest values, observable through `revision`, never placed on the timeline. Deleting the pinned message unpins it.

### Ready-made social overlay

- `HMAudienceBadge` ("1.2K watching", or "1.2K views" without an audience) built on `HMCountFormatter`, with rolling digits and a Reduce Motion fallback; `HMSocialContent.audienceCount`/`viewCount` feed it (nil hides), `HMEngagementSocialAdapter` mirrors the engagement's pushed audience, and `HMSocialOptions.audienceBadgePlacement` places it under the title (default), top-leading, or hides it. `HMTheme.Icon.audience` and `audienceSymbol` theme it.
- `HMSocialOptions.commentSelection` applies an `HMCommentSelection` to the loaded comments for any data source; nil (the default) keeps the data source's own preview candidates. The adapter's default preview is now `.recent` (the two newest comments) instead of the newest three.

- `HMSocialOptions.sheetMode` adds `.snapped(squeezeFraction:)`: the comment sheet rests only at squeezed, expanded or closed, snapping on release by the predicted end of the drag. The expanded sheet pauses playback through the player and resumes on leaving unless the viewer had paused. `HMSocialState` exposes `sheetPosition`, `squeezedSheetHeight`, `snapComments(to:)` and `updateSheetSnapping(squeezedHeight:)`. The default `.continuous` mode is unchanged.
- `allowsPagingWhileSheetOpen` (default true) and the new `hmFeedPagingDisabled` view modifier block feed swipes while the sheet is open. `closesSheetOnVideoTap` (default false) closes the sheet from a tap on the squeezed video instead of ignoring it.
- `HMPlaybackStatusView` shows a delayed buffering spinner and a tap-to-retry failure control sized to the visible video; `showsPlaybackStatus` (default false) places it in the kit's layouts, retrying through `jump(toID:)`. `HMTheme.Icon.retry` and `retrySymbol` theme it.

## 1.0.0

Initial stable delivery from [hotmic-wp/hotmic-player-ios](https://github.com/hotmic-wp/hotmic-player-ios), consolidating pre-release development into one release. `HotMicPlayer.version` and the optional diagnostic aggregate identify the SDK as `1.0.0`.

### Playback and preparation

- Dependency-free MP4 and HLS VOD playback with two products: `HotMicPlayer` for playback/data and optional iOS `HotMicPlayerUI` for rendering. URL playback and custom backends need no HotMic account.
- One player owns the feed, current/next native players, inline and fullscreen surfaces, pause/mute/seek/loop controls and lifecycle cleanup. Visible-frame readiness and first-moving playback are distinct observations; preparing an inactive item does not count as a displayed start.
- Default configuration, public initializer and no-argument player agree: two content players, fixed three entries ahead / one behind, four-second preparation target, 8 MiB per-entry speculative payload cap, adaptive preparation off, and a desired 1,600,000 bits/s startup bandwidth preference for four seconds. The disk cache is globally bounded to 128,000,000 bytes, including pinned entries. One explicit prefix transfer runs at a time.
- Native cache misses stream progressively. Current playback takes priority during startup/stalls; surviving bounded work parks and reprioritizes. Native and prefix readers coalesce in both directions, retire parked shared-resource owners, retain partial bytes and resume the missing suffix. Healthy shared reads remain coalesced.
- HLS preparation selects complete audio/video/init/key/byte-range resources within aggregate budgets, retains immutable playlists and reports unattainable targets. Manifests are bounded to 512 KiB. Unsupported or lengthless HEAD metadata falls back to bounded, budgeted GET probes; unsupported origin Range behavior has an explicit native fallback.
- The default activation trigger uses finger lift when the final aligned target ID is known and settles otherwise. Resize/fullscreen guards preserve navigation ownership and avoid duplicate activation/animation. Next-item preparation is independent of current first frame.
- URL identity retains every query parameter unless the host explicitly names volatile signing parameters. This normalization does not refresh expired signed child URLs; hosts own URL validity and renewal.

### Playlist and failure semantics

- Atomic replace, append, insert, move, remove, jump and ranked-feed reconcile operations use stable IDs and immutable source identity. Display-only refreshes preserve native assignments and shared cache bytes. Overlapping prefetch/resolution survives edits; departing entries cancel their own work.
- `removedCurrentPolicy` defaults to immediate advance. Finish-once removal retains a healthy current visit until end or swipe-away, and advances immediately for failed, failure-idle or ended entries. Empty reconcile is a no-op; history-only refresh settles idle. A finishing visit's media cannot be replaced by a ranked refresh.
- Resolvers coalesce immutable entries and independently cancel waiters; completed results persist for the player lifetime. Resolution automatically attaches newly available current media. Sources/resolvers should cooperate with cancellation.
- Terminal failures skip forward by default, wait for bounded paging recovery when possible, then fall back to a nonfailed previous entry. All-failing playlists terminate. Explicit navigation retries a failed entry; metadata refresh does not erase failure memory. Connectivity/timeout failures remain selected and retry with bounded backoff, paused while hidden, rather than becoming terminal solely from offline duration.

### Rendering, accessibility and host integration

- SwiftUI and UIKit feeds and non-paging inline players share playback/cache behavior. Automatic presentation fills matching portrait media and fits mismatched or landscape media; explicit fit/fill/color/blurred-backdrop policies and aspect hints control first paint. Fullscreen reuses the native player/layer with independent zero-inset geometry and requires host orientation permission.
- Rendering insets, interactive squeezeback, exclusion rectangles, sidecar placement, tap/Fire hooks and host overlay replacement slots preserve playback identity. Single-tap play/pause is on by default; a custom tap callback owns its replacement behavior. Fire is opt-in on custom surfaces.
- VoiceOver Video elements expose Play/Pause and ten-second adjustable playback position; Reduce Motion, dynamic type, caption-safe regions and 44-point auxiliary controls are supported. Hosts should avoid duplicate video accessibility elements.
- Captions include HLS legible-track selection and per-language MP4 WebVTT sidecars, system-following preferences, bounded next-item caption preparation and MediaAccessibility styling.
- Audio defaults to the managed playback/moviePlayback session, with explicit host ownership and background-audio policy. Interruption/output-route/lifecycle handling honors latest host intent; explicit pause prevents unwanted resume. Media-services reset restores the current playhead independently of revisit policy. Background audio also requires host app configuration.
- Visit-scoped URL and host-played ad breaks expose state/progress, permission, skip/cancellation and bounded deadlines. The host owns its ad SDK, consent, targeting and tracking. Hide comment entry points while ads are active. The SDK has no third-party ad dependency.

### Engagement and optional UI

- Backend-independent engagement supports clock-indexed VOD chat, timed reactions, polls, optimistic actions with rollback and authoritative moderation. Bounded per-item deletion records survive engagement eviction; exceeding moderation bounds hides affected engagement rather than forgetting removals.
- Optional item reaction membership/counts and independently paged comment history are separate from media-clock events. Nil counts remain unknown. `.all` retains the original chat/timed-reaction/poll mask; sources explicitly opt into toggle reactions and comment loading. Cancellation is silent and rapid reaction intent is serialized.
- Ready-made social UI provides metadata, Fire/Comment/Share, previews, progress, pause and comment sheets with custom themes and replaceable rail/metadata/sheets. Preview/replay work runs only for the visible current adapter; item comments do not alter timed VOD queries. Hosts retain data sources by item identity and supply share/backend callbacks.
- The separate [HotMicPlayerConnect](https://github.com/hotmic-wp/hotmic-player-connect-ios) adapter's public main branch requires player `from: "1.1.0-alpha.1"`, which cannot resolve a player pinned to `1.0.0`. Compatibility with 1.0.0 is not validated; adapter delivery is separate. The HotMic backend does not yet supply per-stream reactions or paged comment history. Custom backends can implement the full contract.

### Diagnostics, documentation and validation

- Optional aggregate diagnostics are disabled by default. Hosts explicitly select a lifetime sample rate and confirmed collector endpoint/app key. The existing four-argument player initializer is retained; the diagnostics overload requires its explicit fifth argument. Enabling diagnostics does not rebuild the player queue.
- Schema version 1 reports only coarse configuration, nonunique hardware/OS/SDK version, counters and fixed timing histograms. No content/viewer/device identifiers, media URLs/text, raw timestamps, credentials or arbitrary events/properties are encoded. Encoding/transport run off main. Delivery is expendable: fixed-size windows, bounded request/body, no retries, persistence, replay or terminal flush, and lifecycle/playback-pressure cancellation. Sampling and dropped windows bias observations; infrastructure can still observe IP. Review the bundled privacy manifest and host disclosures.
- Collector deployment and availability require separate confirmation. Publishing SDK source does not establish a working live collector. See [Optional diagnostics](Sources/HotMicPlayer/HotMicPlayer.docc/OptionalDiagnostics.md) and the [partner handoff](docs/PARTNER_HANDOFF.md).
- Partner guides cover installation/version policy, playlist operations, backend ownership, accessibility and ad SDK integration. Ready-made/custom overlay starters, player-only/UI examples and a credential-free synthetic Sample use the public API. The separate regression scheme exercises native cancellation and lifecycle behavior. Documentation snippets compile in CI; compiled API inventory and strict DocC checks detect drift.
- Validation includes package regressions, native simulator flows and app/example/device-library compilation. Historical physical observations are documented separately; matched physical-device repeats and settling comparisons remain pending. No physical-device, tvOS-runtime, live-service, bug-free, zero-cost or broad performance guarantee is made.
- Fixed preparation trades bandwidth for readiness; rapid continuous swipes remain bandwidth-bound. Startup bandwidth is a native preference, not an exact rendition/rate guarantee. Compare attempted starts and coverage alongside displayed-frame percentiles, stalls, unused bytes, memory and player bounds in your host app.

### Adoption notes

Use `@unknown default` for non-frozen event enums. Observe ad progress separately from `.playing(kind:)`. `HMEngagement.update(_:)` remains a deprecated alias for `upsertPoll(_:)`; prefer authoritative reaction totals for durable moderation. `teardown()` is terminal; temporary hiding uses `isFeedVisible`. The [historical API review snapshot](docs/API_REVIEW_1.0.md) is distinct from the current [generated public inventory](docs/PUBLIC_API.md).
