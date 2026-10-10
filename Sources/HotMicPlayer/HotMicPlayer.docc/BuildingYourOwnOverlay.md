# Building your own overlay

Build metadata, rails, comment previews, sheets and ads in the host app. The core
`HotMicPlayer` module provides layout and interaction hooks without social visuals.
See `Sample/HotMicPlayerDemo/App/SocialLayoutScreen.swift` (launch with
`--hm-social-layout 1`) for a complete host-built feed using public SDK API.

## Insets and interactive squeezeback

Apply `hmVideoLayout(_:)` to `HMVerticalFeedView` or `HMPlayerView`. Insets move
and resize the video viewport; they do not pad or move the overlay. Rectangles
are in the full surface's local coordinates, with a top-left origin, in points.
For a feed this means the full-bleed page, including safe-area space.

```swift
@State private var layout = HMVideoLayout(
    contentInsets: HMVideoInsets(bottom: 88)
)

HMVerticalFeedView(player: player) { item, snapshot in
    MyOverlay(item: item, paused: snapshot.state == .paused,
              videoFrame: snapshot.videoFrame)
}
.hmVideoLayout(layout)
.hmVideoGestures(onDoubleTap: { point in fire(at: point) })
```

Measure your nav's actual covered height (including the home indicator when
appropriate); do not add that height twice. Use the feed's `hmFeedSafeArea`
environment value to keep overlay controls away from the notch and home bar.
For inline video, measure the host's safe area normally.

As a comment sheet drags, update `layout.squeezeTarget` to the rectangle above
it on every drag update. Set it to `nil` when the sheet closes. The target is
clipped to the inset viewport. Pass the current layout value on each update.

```swift
// fullSize is the measured surface size; sheetHeight follows your interactive drag.
let space = CGRect(x: 0, y: safeTop, width: fullSize.width,
                   height: max(0, fullSize.height - navHeight - sheetHeight - safeTop))
layout.squeezeTarget = sheetHeight == 0 ? nil : HMVideoPresentation.fit.videoFrame(
    aspectRatio: player.snapshot.aspectRatio, in: space
)
```

The fill, fit and backdrop presentation policies still apply inside this
viewport. Automatic policy resolves against the inset viewport before squeeze,
so the policy does not flip during a drag. Overlay snapshots expose the resulting
visible `videoFrame`, excluding fit bars. Insets and squeeze only resize the
existing native layer: they never seek, replace, activate, or rebuffer a node and
never create another first-frame event. Use the host's animation transaction for
open/close; use direct updates during a drag. The SDK adds no animation and does
not remove animations from host overlays. Native layer bounds apply at each layout
update; a host animation of an outer frame alone can jump its native video bounds.
Interpolate the squeeze target itself each animation frame (see the Sample's
`SocialVideoLayout` animatable modifier) to keep the sheet and layer aligned.
Hosts should skip their sheet/progress animation when Reduce Motion is enabled.

UIKit hosts use `HMPlayerViewController.videoLayout`, `excludedHitAreas`,
`isAdPlaying`, `onTap`, `onDoubleTap`, and `videoAccessibilityLabel`. Read
`videoFrame` for the resulting visible bounds, or set `onVideoFrameChange` for
notifications after layout. UIKit respects safe areas by default; opt in with
`extendsUnderSafeArea = true` for a full-bleed container. Custom native hosts can use
`HMVideoLayout.videoFrame(aspectRatio:presentation:in:tolerance:)`. Set
`aspectRatio: nil` to constrain the controller to arbitrary bounds. Property
updates preserve the engine and native layer. For a UIKit-hosted feed, embed
`HMVerticalFeedView` in a hosting controller and supply the same modifiers.
Recompute surface-coordinate rectangles after rotation/fullscreen layout.

Fullscreen defaults to zero insets and no squeeze, independent of inline/feed
layout. Use `.hmFullscreenVideoLayout(layout)` or UIKit `fullscreenVideoLayout`
for separate fullscreen chrome. Explicit inline hit rectangles are dropped;
`HMHitArea` overlays register their new fullscreen bounds automatically. The host
should render its fullscreen overlay without inline nav or sheet padding.

## Hit areas and reserved regions

Wrap each tappable overlay cluster in `HMHitArea`. The container's complete bounds
are automatically reserved, including gaps between its buttons. Alternatively,
apply `.hmExcludedHitArea()` to an individual view. Apply the modifier **after**
padding that is part of the hit area and **before** a full-screen alignment frame.
Do not wrap a full-screen stack containing spacers: that reserves the whole screen.

```swift
HMHitArea {
    VStack {
        Button("Fire", action: fireFromRail)
        Button("Comments", action: openComments)
    }.padding(12)
}
.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
```

Other explicit rectangles (UIKit sibling controls, an external sheet, or regions
with invisible hit slop) go in `.hmExcludedHitAreas([CGRect])`. Their coordinates
must match the surface. Registered rectangles appear in the overlay environment
as `hmReservedRegions`. Native gesture views sit behind host overlays, so controls
receive their own touches. Reservations additionally protect noninteractive gaps
and metadata. Single taps on fit bars do nothing; double taps cover the entire
video viewport, including those bars. Nav space and excluded regions ignore both.

`HMOverlayRegions.freeRects(videoFrame:in:safeArea:contentInsets:excluding:)`
returns disjoint rectangles inside visible video, safe area and nav insets after
subtracting all reservations. Safe-area and content insets use the maximum at each
edge. These rectangles partition the area into disjoint bands, not maximal
rectangles. A sidecar can span multiple bands: test its entire candidate rectangle
with `HMOverlayRegions.isFree(_:videoFrame:in:safeArea:contentInsets:excluding:)`
and register the placed unit as another hit area. The helper reports available geometry; the host decides ad
size, priority and placement. Avoid feeding a sidecar's own reservation back into
its placement search; filter it out or reserve primary controls separately.

## Taps, paused state and accessibility

Single tap toggles playback by default. Supplying `onTap` replaces the default;
call `player.togglePlayPause()` in that callback if you also want to observe it.
`onDoubleTap` receives a surface-coordinate point for the host's one shared Fire
animation. A double tap never invokes the single-tap callback. UIKit's built-in
double-tap failure interval (typically about 0.3 seconds, controlled by the OS)
is the only single-tap delay; no SDK timer adds to it. After Fire, further taps
within 0.3 seconds of the previous Fire also Fire immediately without toggling.
This continuation window extends with each rapid tap. Without a double-tap
callback, single taps do not wait for a second tap. Pending recognizers cancel
when the ad flag disables them. Gestures remain enabled in fullscreen.

Drive `.hmVideoGestures(isAdPlaying: true, ...)` while an ad plays; the ads
integration can drive this flag later. It disables video gestures and video
accessibility actions without disabling the host's own ad controls. Playback
state is available through `snapshot.state`; draw the paused affordance in your
overlay and mark decorative affordances `.allowsHitTesting(false)` and
`.accessibilityHidden(true)`.

The video is an accessibility element with a configurable label and a value
reflecting playback state. VoiceOver activation invokes the single-tap behavior;
localized custom **Play**/**Pause** (based on playback intent, including loading/stalled states) remains available even when the host overrides `onTap`.
When a Fire callback exists, custom **Fire** invokes it at the video frame's center
(no physical tap location exists for an accessibility action). VoiceOver's
activation double tap does not mean Fire. Host controls remain separate
accessibility elements. Test the video and each host control with Accessibility
Inspector and VoiceOver, including while paused, squeezed, fullscreen and in ads.

## Count formatting

`HMCountFormatter(locale:)` formats nonnegative counts with locale-aware digits
and decimal separators, fixed `K`/`M`/`B` suffixes, and no grouping. Negative values
clamp to zero. Counts below 1,000 are exact. Larger counts use thousands, millions
or billions, round half up to one decimal and omit trailing `.0`. Rounding to
1000K or 1000M rolls up to 1M or 1B: 999 → `999`, 1,000 → `1K`,
999,949 → `999.9K`, 999,950…999,999 → `1M`, 1,000,000 → `1M`,
999,950,000 → `1B`, 1,000,000,000 → `1B` (English locale).
The optional HotMicPlayerUI module retains its locale-specific compact names.
