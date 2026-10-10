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

The default decision timeout is **1 second**, configured with `adDecisionTimeout` (clamped to 0.05–10 seconds; nonfinite values use 1). Errors and timeouts fail open to content. Cancellation does not wait for an uncooperative provider: late results are ignored. Cancel your decision/network work cooperatively. A URL break has a separate **5-second** first-displayed-frame deadline, `adLoadTimeout` (0.1–30 seconds; nonfinite values use 5). These deadlines use elapsed wall time, including background time.

## Host-played SDK break

Return `.hostPlayed(HMHostAdBreak(start:stop:))`. `start` receives an `HMHostAdContext` containing `container`, a UIKit view mounted above content and below the host's overlay, inset to the page's safe area. It may not yet be in a window when `start` runs; use normal view layout callbacks. Attach your SDK's view, use aspect fit, and retain your existing skip/countdown UI. The container follows feed, standalone and fullscreen rendering ownership. Content stays paused at zero and prerolled underneath; the existing decoded frame is reused on completion when ready.

```swift
return .hostPlayed(HMHostAdBreak(start: { context in
    sdk.render(in: context.container, aspectFit: true)
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

Bridge SDK callbacks onto the main actor. `complete()`, `skip()` and `fail()` are one-shot; old contexts become inert. `stop` runs once on any terminal outcome, including swipe-away, replacement or teardown. The host owns SDK pause/background behavior and any maximum break duration; there is no timeout after a host break starts. Only the decision and URL startup are bounded by the player.

## Player-played URL break

Return `.preRoll(HMMediaItem(...))` with a directly playable file, MP4 or HLS URL. The same AVFoundation engine plays it using **fit**, preserving landscape aspect ratio with black bars inside the safe area, regardless of the content's crop, squeeze or presentation policy. No skip UI is supplied. The host's existing skip/countdown UI reads `adState` and calls `skipAd()`. URL ads use one temporary engine in addition to the content pool so current content and the next content head keep their assignments. The ad engine is released at the end. URL playback is direct; a host may supply an already-cached local URL. Ad URLs need not be playlist entries and cannot evict content by sharing an ID.

Content starts at zero after an accepted break, including when position restoration is enabled. Content TTFF starts at the end of the break, excluding intentional ad time; ad state/outcome timestamps retain the break's elapsed time. No-fill preserves the original navigation clock. Content play/pause and visibility still govern whether content resumes; URL playback also obeys mute/pause/visibility. Seek and video tap/double-tap/accessibility actions are inert during loading and playing.

## State, swipes and prefetch

Observe `adState`: `.none`, `.loading`, `.playing(kind:progress:)`, `.finished`. Loading includes the decision and URL startup. Hide the comment icon, comment preview and squeezeback trigger whenever `adState.isActive` is true. Progress is elapsed/duration in seconds, with optional `fraction` when duration is known. Host SDK adapters supply host progress; URL progress updates about five times per second. `HMPlayer.events` emits `adStateChanged`, `adBreakEnded` and `adPrefetchChanged`. The same named analytics events include state, outcome and pause/resume properties, associated with the content ID; ad playback does not create a content impression.

Feed swipes are allowed by default. Swiping away cancels the decision/break and emits `.cancelled`; revisiting consults again. Set `allowsSwipeDuringAds = false` to block feed paging during a pre-roll. Explicit host playlist navigation remains available for dismissal or replacement.

**Ad loading/playing deliberately deprioritizes next-video prefetch.** Bulk speculative prefix downloads pause immediately. The current content preroll and next content head remain protected; with the default two-player pool, both can decode. A one-player configuration retains only current's decoder. Preparation is bounded by the configured warm head, rather than the entire bulk window. Bulk work resumes through the normal buffer-safety policy after any terminal outcome; events expose the ad gate's pause/resume separately from that policy.

Sidecars/companion units stay host-owned overlays and do not enter the pre-roll hook or disable swiping. Use `HMOverlayRegions.freeRects`/`isFree` and `hmExcludedHitArea()` to place and reserve their regions. Preserve SDK tracking beacons, targeting, consent, skip eligibility, countdown and companion placement in your existing stack. No third-party ad SDK or network calls are added by HotMicPlayer.

The Sample's **Ads lab** demonstrates both modes offline, with a generated landscape MP4, a colored host break and state-driven comment suppression. Its benchmark `ads` scenario plays a local pre-roll before measuring subsequent content swipes.
