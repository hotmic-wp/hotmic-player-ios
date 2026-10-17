# Ads

Keep decisioning, tracking and ad UI in your existing stack while presenting pre-rolls in the player's container.

## Choose a break before content

Assign an `HMAdBreakProvider` to `HMPlayer.adBreakProvider` before loading the playlist. The main-actor async method `adBreak(for:)` runs on activation, once per item visit. Returning to an item consults again; metadata edits, pause/resume and fullscreen do not. The host can implement its own frequency caps or return `.none` for already-served playlist attachments. Content never activates before the decision.

```swift
@MainActor final class Ads: HMAdBreakProvider {
    let attachedPreRoll: URL
    init(attachedPreRoll: URL) { self.attachedPreRoll = attachedPreRoll }
    func adBreak(for item: HMMediaItem) async throws -> HMAdBreak {
        guard item.metadata["hasPreRoll"] == "true" else { return .none }
        return .preRoll(HMMediaItem(id: "attached-ad", url: attachedPreRoll, format: .mp4))
    }
}
player.adBreakProvider = Ads(attachedPreRoll: preRollURL)
```

The default decision timeout is **1 second**, configured with `adDecisionTimeout` (clamped to 0.05–10 seconds; nonfinite values use 1). Errors and timeouts fail open to content. Cancellation does not wait for an uncooperative provider: late URL/no-fill results are ignored, and late host adapters receive `stop(.cancelled)` without starting. Cancel your decision/network work cooperatively. A URL break has a separate **5-second** first-displayed-frame deadline, `adLoadTimeout` (0.1–30 seconds; nonfinite values use 5). These deadlines use elapsed wall time, including background time.

## Host-played SDK break

Return `.hostPlayed(HMHostAdBreak(start:stop:))`. `start` receives an `HMHostAdContext` containing `container`, a UIKit view mounted above content and below the host's overlay, inset to the page's safe area. It may not yet be in a window when `start` runs; use normal view layout callbacks. Attach your SDK's view, use aspect fit, and retain your existing skip/countdown UI. The container follows feed, standalone and fullscreen rendering ownership. Content stays paused at zero and prerolled underneath; the existing decoded frame is reused on completion when ready.

The following is **non-compiled pseudocode** for your existing third-party SDK wrapper; no ad SDK is linked by HotMicPlayer.

```text
return .hostPlayed(HMHostAdBreak(start: { context in
    sdk.render(in: context.container, aspectFit: true)
    sdk.setPlaybackAllowed(context.isPlaybackAllowed)
    context.onPlaybackAllowedChange = { sdk.setPlaybackAllowed($0) }
    sdk.onProgress = { elapsed, duration in
        context.updateProgress(HMAdProgress(elapsed: elapsed, duration: duration))
    }
    sdk.onComplete = { context.complete() }
    sdk.onSkip = { context.skip() }
    sdk.onFailure = { context.fail() }
}, stop: { outcome in
    sdk.stopAndRelease()
}))
```

Bridge SDK callbacks onto the main actor. `complete()`, `skip()` and `fail()` are one-shot; old contexts become inert. `stop` runs once on any terminal outcome, including swipe-away, replacement or teardown. A late host adapter receives `stop(.cancelled)` without starting.

The host must honour observable `context.isPlaybackAllowed` or `onPlaybackAllowedChange` by pausing SDK video and audio when false, and resuming when true. Read its initial value during `start` as well as subscribing to changes. Visibility, backgrounding and explicit player pause update this signal. Supply media progress so the no-progress watchdog can detect a stuck SDK.

Every accepted break has a **120-second** wall-clock cap (`adBreakMaxDuration`, clamped to 0.1–3600 seconds) and a **10-second** no-progress watchdog (`adNoProgressTimeout`, 0.1–120 seconds). Nonfinite values use the defaults. Unchanged elapsed media time counts as no progress even if duration or repeated callbacks change. The watchdog is suspended while playback is disallowed; the wall-clock cap still applies while hidden or paused. Both timeouts emit `.timedOut`, release the ad and yield to content.

## Player-played URL break

Return `.preRoll(HMMediaItem(...))` with a directly playable file, MP4 or HLS URL. The same AVFoundation engine plays it using **fit**, preserving landscape aspect ratio with black bars inside the safe area, regardless of the content's crop, squeeze or presentation policy. No skip UI is supplied. The host's existing skip/countdown UI reads `adState` and calls `skipAd()`. URL ads use one temporary engine in addition to the content pool so current content and the next content head keep their assignments. The ad engine is released at the end. URL playback is direct; a host may supply an already-cached local URL. Ad URLs need not be playlist entries and cannot evict content by sharing an ID.

Content starts at zero after an accepted break, including when position restoration is enabled. Completed and skipped breaks reset content TTFF to the end of the break. Failed and timed-out breaks retain the navigation clock, including black startup time; no-fill also retains it. Content `viewStart` and `firstFrame` analytics include `after_ad` and, after an accepted break, `ad_outcome`. An accepted break resets prior paused intent to autoplay; content autoplays after it, unless the host explicitly pauses again. Visibility still governs whether playback may resume. URL playback obeys mute, pause and visibility. Seek and video tap/double-tap/accessibility actions are inert during loading and playing.

## State, swipes and prefetch

Observe `adState`: `.none`, `.loading`, `.playing(kind:)`, `.finished`. Loading includes the decision and URL startup. Hide the comment icon, comment preview and squeezeback trigger whenever `adState.isActive` is true. Observe `adProgress` separately for elapsed/duration in seconds, with optional `fraction` when duration is known. Host SDK adapters supply host progress; URL progress updates about five times per second. Progress ticks emit no lifecycle events or analytics. `HMPlayer.events` emits `adStateChanged`, `adBreakEnded` and `adPrefetchChanged`. State analytics use fixed `none`/`loading`/`playing`/`finished` strings, with a separate `kind` property for playing. Analytics include outcome and pause/resume properties associated with the content ID; ad playback does not create a content impression.

Feed swipes are allowed by default. Swiping away cancels the decision/break and emits `.cancelled`; revisiting consults again. Set `allowsSwipeDuringAds = false` to block feed paging during a pre-roll. Explicit host playlist navigation remains available for dismissal or replacement.

**Ad loading/playing deliberately deprioritizes next-video prefetch.** Bulk speculative prefix downloads pause immediately. The current content preroll and next content head remain protected; with the default two-player pool, both can decode. A one-player configuration retains only current's decoder. Preparation is bounded by the configured warm head, rather than the entire bulk window. Bulk work resumes through the normal buffer-safety policy after any terminal outcome; events expose the ad gate's pause/resume separately from that policy.

Sidecars and other host-owned overlays do not enter the pre-roll hook or disable swiping. Use `HMOverlayRegions.freeRects`/`isFree` and `hmExcludedHitArea()` to place and reserve their regions. Companion video ads are the exception: the same visit decision can arm one with `.companion`, and the player then owns the band, the trigger and the audio hold (see Companion ads below). Preserve SDK tracking beacons, targeting, consent, skip eligibility, countdown and banner placement in your existing stack. No third-party ad SDK or network calls are added by HotMicPlayer.

Decisions never trim existing warm players, including when the provider returns no fill. Accepted breaks also retain existing neighbours; only new speculative preparation is blocked. The next head may use a free pool slot without evicting an existing neighbour.

The Sample's **Ads lab** demonstrates both modes offline, with a generated landscape MP4, a colored host break and state-driven comment suppression. Its benchmark `ads` scenario plays a local pre-roll before measuring subsequent content swipes. The `no-fill` scenario compares normal back-and-forth swipes with a provider returning `.none` against a control without a provider.

## Companion ads

A companion ad is a video ad shown in a band at the bottom of the feed while content keeps playing; it is not a VAST companion banner. Return `.companion(HMCompanionBreak)` from the same visit decision instead of a pre-roll. Content starts at once, exactly as after `.none`, the visit ends with `adBreakEnded(outcome: .companion)`, and the companion is **armed** at the player level: it appears after the trigger's watched time, stays pinned across swipes, `next()`/`previous()`, `jump(toID:)` and playlist edits until it ends, and never gates comments, the sheet or chrome (`adState` is not involved). `dismissCompanion()` ends it for host navigation such as leaving the screen, and `teardown()` ends it too.

```swift
@MainActor final class CompanionAds: HMAdBreakProvider {
    let creativeURL: URL
    init(creativeURL: URL) { self.creativeURL = creativeURL }
    func adBreak(for item: HMMediaItem) async throws -> HMAdBreak {
        guard item.metadata["companion"] == "true" else { return .none }
        let creative = HMMediaItem(id: "companion-creative", url: creativeURL, format: .mp4)
        return .companion(.media(creative, clickThroughURL: URL(string: "https://example.com/offer"),
                                 trigger: HMCompanionTrigger(watchedTime: 10, countdown: 5, scope: .session)))
    }
}
player.adBreakProvider = CompanionAds(creativeURL: preRollURL)
```

At most one companion exists. A `.companion` decision while one is armed, counting down or playing is declined: a host adapter receives `stop(.cancelled)` without starting, the visit ends `.cancelled` with the analytics reason `companionActive`, and the existing companion is untouched; read `companionState` before requesting one. A later visit whose decision is accepted as a pre-roll cancels an armed or playing companion before the pre-roll starts (reason `preRoll`); `.none`, no fill and failed decisions leave it alone.

**Trigger and countdown.** `HMCompanionTrigger` counts **watched time**: content seconds actually watched, summed from positive playhead progress while content plays, never a playhead position. Seeks, loops, stalls, pauses and background time add nothing, fullscreen content counts, and seconds watched before arming never count. `.session` counts from arming across items; `.item` counts the current item since it was joined and restarts on each item change while the companion stays armed, which suits live content. `HMPlayerConfiguration.companionTrigger` supplies the default (10 watched seconds, a 5-second countdown, `.session`) and a break's own `trigger` overrides it; values are sanitized when used. The companion is *presentable* while a feed surface is attached and visible, not in fullscreen, the app is active, `suppressesCompanionAds` is false, no surface covers the band and no pre-roll is playing. `.armed` becomes `.countdown` when the remaining watched time reaches the countdown length and the companion is presentable; during the countdown the remaining time advances only while presentable, otherwise the sample's `rate` is zero and the number freezes. `companionCountdown` holds the latest sample while armed or counting down; draw the number on the wall clock from `estimatedRemaining(at:)`, for example in a `TimelineView`. Samples arrive without events or analytics.

**Creatives and deadlines.** `.media` plays a directly playable MP4, HLS or file URL in its own engine outside the content pool, warmed when the countdown begins and released at the end; it starts muted. If its first frame is not ready when the countdown reaches zero, the state holds `.countdown` until the frame or `adLoadTimeout`, which ends it `.timedOut`. `.hostRendered` renders into `HMHostAdContext.container`, which is the band; `start` runs when the band appears with the container in a window, never earlier, so preload during the decision if your SDK needs lead time. From presentation, `adNoProgressTimeout` (suspended while playback is disallowed) and the `adBreakMaxDuration` wall cap apply as for pre-rolls; `complete()`, `skip()` and `fail()` are one-shot, and `stop` runs once on every outcome. `skipCompanion()` ends a playing companion as skipped; offer a close control only when your ad stack allows it.

**Layout.** `HMVerticalFeedView` draws the band as one layer above the pager, outside the cells: full width, `width / aspectRatio` tall (capped at a third of the inset viewport), docked above `contentInsets.bottom` and the bottom safe area, sliding in and out over about 300 ms and instantly under Reduce Motion. While presented, every page's viewport is reduced from the bottom by the band through the squeeze path, with the presentation policy resolved before the squeeze; a host `squeezeTarget` intersects with it, so a comment sheet sits above the band. Overlay snapshots carry the band in `companionFrame`, and the band joins `hmReservedRegions`, so `isFree`, sidecars and captions avoid it. The band owns its touches, and VoiceOver reads it as an advertisement. Companions cannot be presented in fullscreen or on an inline `HMPlayerView` alone; a playing companion's band is hidden and paused there. Draw player-level chrome with `hmCompanionOverlay` on the feed: it receives an `HMCompanionOverlayContext` with the player, the band frame and the click-through URL, and swipes never move it. The core draws no companion chrome of its own.

**Audio.** `isCompanionMuted` is independent of `isMuted` and is set to `true` each time a companion appears. Unmuting places a hold on content: the content engine pauses, `wantsPlayback` and `isMuted` are unchanged, and watched time stops. The hold is released, and content resumes when the viewer wants playback and it is allowed, on re-mute, when the companion ends, on `play()` or `togglePlayPause()` of held content (both re-mute the companion), and on navigation to another item (which also re-mutes it). A viewer `pause()` during the hold leaves content paused after release. A host-rendered companion mirrors the state into `context.isMuted` / `onMutedChange`, and `context.reportMuted(_:)` reports the SDK's own control.

**Cover and suppression.** Report surfaces that cover the band with `setCompanionCovered(_:by:)`, using one stable name per surface; clearing one never clears another, and `isCompanionCovered` reads the union. A covered, suppressed, hidden or fullscreen companion does not appear and its countdown freezes; a playing one gets `isPlaybackAllowed = false` (the URL engine pauses) and resumes when presentable again, with the band staying pinned. Backgrounding behaves as for pre-rolls. Companions never pause bulk prefetch or evict content heads.

**Events.** `companionState` is `.none`, `.armed`, `.countdown` or `.playing(kind:)`; `isPresented` is true while the band is on screen. `companionProgress` is the creative's media time while it plays. `HMPlayer.events` emits `companionStateChanged(item:state:)` and, exactly once per armed companion, `companionEnded(item:outcome:)`; the item is the one whose decision armed it. Analytics use fixed strings: `companionStateChanged` carries `state` (`none`, `armed`, `countdown`, `playing`) plus `kind` while playing, and `companionEnded` carries `outcome` plus `reason` (`preRoll`, `dismissed`, `teardown`, `companionActive`) when cancelled. The ready-made social overlay draws a countdown pill and a band strip with a "Learn more" control and a mute toggle; see [Ready-made social overlay](https://github.com/hotmic-wp/hotmic-player-ios/blob/main/Sources/HotMicPlayerUI/HotMicPlayerUI.docc/ReadyMadeSocialOverlay.md) in HotMicPlayerUI.

## Picture in Picture and AirPlay

The SDK owns no Picture in Picture controller: set `HMPlayer.isPictureInPictureActive` from your `AVPictureInPictureControllerDelegate`. `isExternalPlaybackActive` follows the external route, such as AirPlay, of the engine playing current content; it moves with that content across swipes and engine reuse, and stays false while the player is idle. `suppressesCompanionAds` is true while either is active. Companion ads do not appear while Picture in Picture or external playback is active, and a playing companion pauses. `HMPlayer.events` emits `externalPresentationChanged(pictureInPicture:externalPlayback:)` on each effective change of either flag.

## Source compatibility

Ad integration adds cases to `HMPlayerEvent` and `HMPlaybackEvent.Kind`. Companion ads add `HMAdBreak.companion`, `HMAdOutcome.companion`, three `HMPlayerEvent` cases (`companionStateChanged(item:state:)`, `companionEnded(item:outcome:)` and `externalPresentationChanged(pictureInPicture:externalPlayback:)`) and two `HMPlaybackEvent.Kind` cases (`companionStateChanged` and `companionEnded`). Update exhaustive switches to handle the ad events when upgrading, and use `@unknown default` when ignoring future SDK enum cases. `HMAdState.playing(kind:)` describes a phase; progress lives in `HMPlayer.adProgress`.

## Ad SDK adapter recipe (for example, Google IMA)

Keep a host adapter for each accepted visit. Your app owns the third-party dependency and an app-scoped loader. The adapter translates SDK delegates into the context contract. See [Google's iOS IMA setup](https://developers.google.com/interactive-media-ads/docs/sdks/ios/client-side/get-started) for loader, request, display container and manager wiring.

The following is **non-compiled pseudocode**, intentionally written against a host `IMAVisit` facade. Implement that facade with your SDK version; no Google package dependency is added here.

```text
@MainActor final class HostAds: HMAdBreakProvider {
    let loader: AppScopedIMALoader
    func adBreak(for item: HMMediaItem) async throws -> HMAdBreak {
        // Make the bounded decision here. Return .none for no fill/frequency cap.
        guard shouldServe(item) else { return .none }
        let visit = IMAVisit(loader: loader, tag: hostAdTag(item))
        return .hostPlayed(HMHostAdBreak(start: { context in
            // Create IMAAdDisplayContainer with context.container and your presenter.
            // Wait for mounting/layout if your SDK requires a window before requesting.
            visit.onLoaded = { manager in
                // Set IMAAdsManagerDelegate, initialize rendering settings;
                // start on LOADED only if context.isPlaybackAllowed.
                manager.initialize()
            }
            visit.setPlaybackAllowed(context.isPlaybackAllowed)
            context.onPlaybackAllowedChange = { visit.setPlaybackAllowed($0) }
            visit.onProgress = { seconds, duration in
                context.updateProgress(HMAdProgress(elapsed: seconds, duration: duration))
            }
            visit.onAllAdsCompleted = { context.complete() }
            visit.onUserSkipped = { context.skip() }
            visit.onRequestOrPlaybackError = { context.fail() }
            visit.request(in: context.container, presenter: hostPresenter)
        }, stop: { outcome in
            visit.cancelPendingRequest() // late loader callbacks must be ignored
            visit.destroyManagerAndRemoveViews()
            visit.clearCallbacks() // release context and permission listener
        }))
    }
}
```

Map your SDK's terminal **break** completion rather than the end of the first creative in a pod. Marshal all callbacks to the main actor and guard stale visit IDs, including manager callbacks arriving after `stop`. Honor initial playback permission and subsequent changes, including during a load. Keep SDK skip/countdown and tracking in the host; never call skip before it is eligible. For Google IMA, loader failures and manager errors fail the context, manager progress updates the watchdog, and all-ads-completed ends the break. Normal content pause/resume delegates must not bypass HotMicPlayer's ad state machine.

Request time inside `start` is bounded by the no-progress watchdog (10 seconds by default) and the accepted break wall-clock cap (120 seconds). Decision work before returning the break uses `adDecisionTimeout` (1 second). URL startup instead uses `adLoadTimeout` (5 seconds). Configure these on `HMPlayerConfiguration` before constructing the player. On timeout/cancellation, `stop` releases SDK resources; ignored late callbacks cannot restart content or ads. Hosts without an SDK can use the compiled URL provider above and retain their own skip/countdown UI.
