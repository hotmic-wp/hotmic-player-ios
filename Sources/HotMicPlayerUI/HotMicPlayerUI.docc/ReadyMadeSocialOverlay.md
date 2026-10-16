# Ready-made social overlay

Ship a themeable vertical-video social experience, or compose your own interface on the same public hooks.

## Choose the integration level

Use `HMSocialPlayerView` for a complete feed or inline player: metadata, ephemeral preview, Fire/Comment/Share rail, progress, caption toggle and an interactive comment sheet. `HMSocialPlayerViewController` embeds the same SwiftUI implementation in UIKit; add it as a child controller and constrain its view. Playback remains owned by your `HMPlayer`.

For custom chrome, depend only on HotMicPlayer and use `hmVideoLayout`, `HMVideoLayout.squeezeTarget`, `hmVideoGestures`, `HMHitArea`, `hmReservedRegions` and `HMOverlayRegions.isFree`. The optional kit uses those same public APIs and has no private engine access. Existing `HMOverlayLayout`, `HMChatRail` and engagement components remain available with their original initializers. `HMActionRail` has an additional backend-independent social initializer, rather than a second rail implementation.

Cached adapters must follow engagement identity, not only item ID. The player may rebuild an evicted engagement. Resolve `let engagement = player.engagement(for: item)`; return a cached adapter only if `adapter.engagement === engagement`, otherwise replace it. Mapping is lazy and source changes are visible synchronously. The kit calls `setReplayActive` only for the current visible adapter; a custom consumer must keep a stable UUID per view instance, enable it with `setReplayActive(true, for: token)` while current and disable the same token with `setReplayActive(false, for: token)` when hidden. Inactive cached adapters do no clock work.

## Data in, events out

Implement `HMSocialDataSource` on an observable main-actor model, or fill `HMSocialModel`. Its `HMSocialContent` contains title, description, community, hashtags, optional counts, viewer membership, preview candidates and loaded comments. Nil counts stay hidden. Stable comment IDs identify rows across page loads. Keep each data source alive by media item ID; update it as backend pushes arrive.

The data source owns network actions, pagination cursors, authoritative results, optimistic updates and rollback. `setReacted` receives the intended membership, `loadMoreComments` loads the next page, and `postComment` posts a draft. Throw errors to display them; failed comment submissions preserve the draft. The default sheet serializes its own page loads and submissions. `HMSocialModel` action closures must update `content` with resulting state; its defaults do not invent server success or counts.

`HMEngagementSocialAdapter` supplies this contract from `HMEngagement`, including custom backend and Connect interaction sources. It uses authoritative item summaries, independent comment pages and `sendChat`. Pass the same `HMTheme` to its `theme` parameter and the overlay; membership and counts follow `theme.primaryReaction`. The adapter caches mapped rows against public engagement revisions, metadata, selection and reaction changes. Backend changes are mapped synchronously on the next `content` read. Only the current visible adapter samples replay time, and only changed replay rows invalidate chrome. Replay comments appear at their media timestamps with up to a 100 ms sampling interval. Its `previewSelection` closure lets the host choose candidates independently of the list's paging policy. No Connect dependency is added to the UI product.

```swift
var options = HMSocialOptions()
options.hostNavigationHeight = 54 // excludes the home-indicator safe area
options.showsMute = false
options.allowsScrubbing = false

var callbacks = HMSocialCallbacks()
callbacks.hashtagTapped = { tag in host.openHashtag(tag) }
callbacks.share = { item in host.presentShare(item.url) }

HMSocialPlayerView(player: player, options: options, callbacks: callbacks) { item in
    host.socialData(for: item) // a retained HMSocialDataSource
}
```

Other callbacks report successful Fire changes and comment posts, plus sheet opening/closing (including cancellation on item changes, fullscreen, ad activation and view removal). `HMShareSheet(items:)` wraps `UIActivityViewController` for SwiftUI `.sheet`; UIKit can call `HMShareSheet.present(items:from:sourceView:)` with a popover anchor. `ShareLink` is also suitable in a custom interface.

## Composition and customization

Each piece is usable alone: `HMMetadataView`, `HMCommentPreview`, `HMActionRail`, `HMFireBurst`, `HMProgressBar`, `HMCommentSheet`, `HMPlayPauseAffordance` and `HMPlaybackStatusView`. A standalone `HMSocialOverlay` needs the matching `hmSocialPlayback(player:state:options:extendsUnderSafeArea:data:callbacks:)` modifier on its ancestor feed or inline surface. Share one `HMSocialState` between them. For an inline surface already constrained inside the safe area, pass `extendsUnderSafeArea: false` to the modifier; `HMSocialPlayerView` chooses this automatically. The modifier applies video insets, interactive squeeze and public native tap recognizers; the overlay cannot change an ancestor's video layout by itself.

The host supplies navigation separately; pass only its content height, excluding system bottom safe area. Video fills the remaining viewport and shifts upward. Metadata and progress sit above navigation and outside the rail. Preview occupies its own row below the rail and above metadata. The default metadata expands in a separate sheet. At accessibility text sizes, resting metadata condenses into a title and expansion action and previews are omitted; full details remain in the expansion sheet. The feed overlay has no nested vertical scroll views, so rail and metadata swipes continue to page, including at larger text sizes.

Previews are visible for `previewDuration` and then disappear. `previewRotationInterval` controls the rotation period; nil shows only the first host-selected comment once per item for the shared social-state lifetime, including across sheet/ad/fullscreen dismissal and return swipes. Rotating previews reset selection when the current item changes and pause during sheets, ads and fullscreen. Preview scheduling begins after the first displayed frame and reacts to candidate arrivals without polling. Tap always opens the full sheet. Hosts can provide a single candidate and disable automatic rotation.

Which comments are previewed is a rule, `HMCommentSelection`: a named strategy plus a limit, with a stable wire form (`{"rule":"recent","limit":2}` or the `rule`/`limit` query items) so a backend endpoint and the client speak the same vocabulary and a server-chosen list is interchangeable with a client-chosen one. `.recent` (the two newest by list order) is the rule today; `topReactions`, `verifiedOnly` and `pinnedFirst` are reserved names, and an unknown rule previews as recent. Applying a rule is a pure function over the oldest-first comment list: it never reads a clock and keeps the input order, so rotation is the same everywhere. `HMSocialOptions.commentSelection` applies a rule to `content.comments` for any data source; nil (the default) shows the data source's own `previewComments`, which is where a server-chosen list belongs. `HMEngagementSocialAdapter` previews `.recent` unless its `previewSelection` closure is replaced.

`HMAudienceBadge` shows "1.2K watching" from `HMSocialContent.audienceCount`, or "1.2K views" from `viewCount` when there is no audience; nil hides it, and a real zero is shown. The adapter mirrors `HMEngagement.audienceCount`, a value the source pushes with `updateAudienceCount(_:)`; recorded views stay host metadata. Refresh cadence belongs to the source: push a live audience at least every ten seconds, and the kit animates the change (rolling digits, or an in-place switch under Reduce Motion) without polling. `audienceBadgePlacement` puts the badge under the title (the default), in the top-leading corner of the visible video, or hides it. VoiceOver reads the exact count.

The default sheet supports handle dragging, accessible resizing and a close button. Every drag update changes `squeezeTarget` without changing playback. Viewport constraints and keyboard clearance clamp the shared state, so the visible sheet and video use exactly the same height.

`sheetMode` chooses how the sheet rests. The default `.continuous` keeps any dragged height and closes below the dismiss threshold. `.snapped(squeezeFraction:)` has three rest positions only: squeezed (the video keeps that fraction of the viewport height, anchored at the top, with the sheet below it), expanded (the sheet reaches the top safe area and the kit pauses playback through `HMPlayer`, resuming when the sheet leaves that position unless the viewer had paused) and closed. A release snaps to the nearest position using the predicted end of the drag, so the last gesture decides the end state and no intermediate height persists. `HMSocialState.sheetPosition` reports the rest position and `snapComments(to:)` moves between them; the kit calls `updateSheetSnapping(squeezedHeight:)` on every layout pass. Rest heights follow host navigation rather than the keyboard, so the squeezed video holds its size while composing.

Two further options change feed interaction while the sheet is open. `allowsPagingWhileSheetOpen` (default true) set to false applies `hmFeedPagingDisabled` to the feed, so swipes on the squeezed video do nothing until the sheet closes; programmatic navigation still closes it. `closesSheetOnVideoTap` (default false) makes a tap on the squeezed video close the sheet instead of being ignored; it never toggles playback. Both default to the current behavior.

`showsPlaybackStatus` (default false) draws `HMPlaybackStatusView` inside the visible video frame in every layout, including the squeezed and fullscreen sizes: a delayed spinner while loading or buffering, and a "Couldn't play this video, tap to retry" control once playback fails, which calls `jump(toID:)` on the failed entry. The view reads only the coarse playback state, so live DVR windows behave like VOD. With `failedItemPolicy = .skip` the player moves on by itself; pair the control with `.stay` to let the viewer retry in place. `.commentSheet { item in ... }` replaces its list/composer while retaining the sheet and squeeze shell. Replacement content owns posting and its callbacks. `.actionRail { item, context in ... }` and `.metadata { item, context in ... }` replace those pieces too; their contexts expose shared actions, counts, hashtag/expansion routing, and the custom Fire glyph frame hook. The standalone overlay offers equivalent one-context builders. `HMSocialPlayerViewController(content:theme:)` embeds a customized surface and derives its player from that content. `.sidecar(size:) { item in ... }` supplies a fixed-size slot that is shown only if the entire rectangle passes `isFree` inside the visible video against safe area, navigation and registered controls. If no slot fits, the sidecar stays hidden. Register extra host chrome with `hmExcludedHitAreas` on the surface ancestor so it also participates. Hosts needing other placements can use the individual components and public region API.

The kit observes `adState.isActive`, including decisioning, and suppresses the rail, preview, Fire and comment trigger. Metadata and progress stay visible unless the host sets `hidesMetadataDuringAds`. An open sheet closes when an ad starts. Hosts own ad SDK skip/countdown UI. Captions use `availableCaptionLanguages` and `captionsEnabled`; CC stays hidden without tracks, and registered control bounds are reserved for caption placement. Mute is off as a control by default; audio starts on with the player's default configuration and mute state belongs to the shared player across swipes. Looping stays at the player's default; the kit never advances items on completion.

Landscape items use the player's automatic letterboxing policy. Fullscreen has independent zero-inset video layout, no navigation or social rail, and only playback, optional mute, CC and exit controls in a pill at the bottom. `fullscreenControls` decides how long that pill stays: `.visible` (default) keeps it for the whole session; `.autoHide(after:)` shows it on entry and whenever playback is not running, hides it that many seconds into playback, and brings it back after any change it can make (play, pause, mute, captions); `.hidden` never draws it, so nothing but the player's corner exit sits over the video and a tap plays or pauses. Every value keeps a way out: the player's own corner exit button, device rotation when the host follows it, and VoiceOver's escape gesture on the fullscreen surface. Mute and captions stay reachable as VoiceOver custom actions on the video element while the pill is away.

## Theme

Apply `.hmTheme(theme)` above the player. Existing palette, Dynamic Type fonts, SF Symbol names, corner radius and reaction palette remain source-compatible. `customImages` overrides social icons with host `Image` assets; `railSpacing`, `fireAnimationDuration` and `sheetAnimationDuration` tune layout and motion. Symbol fallbacks for captions, fullscreen, play/pause and close are also configurable.

```swift
var theme = HMTheme.default
theme.colors.accentSecondary = .orange
theme.customImages[.fire] = Image("BrandFire")
theme.railSpacing = 12
theme.cornerRadius = 16
```

Fire taps and video double taps enter `HMSocialState.fire` and use one `HMFireBurst` event. Rail tap toggles membership; double tap adds it without undoing a previous reaction. The burst originates at the tap and resolves into the same rail icon. Only new positive Fire events play it: un-react, return swipes, sheet/ad dismissal and fullscreen exit never replay a consumed event. Reduce Motion uses a stationary highlight with no movement, and sheet transitions do not animate. The public native video element supplies a VoiceOver Fire custom action. Controls expose button labels and values, including Fire reacted/not reacted with its optional exact count, comment/share counts, mute and CC; text follows Dynamic Type and uses a dark scrim for contrast over video.

Kit strings currently use English localization keys in the host main bundle; the package does not ship translated catalogs. Supply host `Localizable.strings`/String Catalog entries for keys such as “Comments”, “Close comments”, “Resize comments”, “Show more”, “Show less”, “About this video”, “Couldn't play this video”, “Tap to retry” and “Loading”, and audit all controls with your supported locales. Replace rail/metadata/sheet slots when your localization needs differ. Standalone `HMMetadataView` should provide `onExpand` to a scrollable host presentation for full metadata at accessibility sizes; it suppresses inline expansion there to keep the resting stack bounded.

## Behavior mapping

| Requirement | Component / public API |
| --- | --- |
| Persistent host navigation, video shifted upward | `hostNavigationHeight`, `hmVideoLayout` content insets |
| Metadata, expandable description, community, hashtags and progress | `HMMetadataView`, `hashtagTapped`, `HMProgressBar` |
| Ephemeral preview, no overlap, host rotation, tap to sheet | `HMCommentPreview`, preview candidates, duration/rotation options, `openComments` |
| Recent comments on the video, selection rule configurable and shared with the backend | `HMCommentSelection` (`.recent`, reserved `topReactions`/`verifiedOnly`/`pinnedFirst`), `commentSelection`, adapter `previewSelection` |
| People watching now on the video, or views for recorded media | `HMAudienceBadge`, `audienceCount`/`viewCount`, `HMEngagement.updateAudienceCount(_:)`, `audienceBadgePlacement`, `HMCountFormatter` |
| Fire/Comment/Share rail, reaction animation, native share | Existing `HMActionRail` social initializer, shared state, `HMFireBurst`, `share`, `HMShareSheet` |
| Audio on, optional persistent mute | Player defaults, `showsMute`, `HMPlayer.isMuted` |
| Loop without automatic advance | `HMPlayerConfiguration.loops`, no kit advancement |
| Same Fire burst for surface double tap and rail | `hmVideoGestures`, `HMSocialState.fire`, registered `HMHitArea` bounds |
| Tap playback, lightweight pause, visible chrome | Native tap hook, `HMPlayPauseAffordance`, resting layout |
| Continuous progress, opt-in scrubbing | Snapshot playhead, `HMProgressBar`, `allowsScrubbing`, interaction begin/end |
| Caption control only with tracks | `availableCaptionLanguages`, `captionsEnabled` |
| Accessibility and contrast | Button labels/values, native Fire custom action, theme fonts, scrim, Reduce Motion |
| Host-provided compact counts | Nil hides counts; `HMCountFormatter` |
| Safe area | `hmFeedSafeArea` plus inline/fullscreen geometry safe insets |
| Default or replacement interactive squeezed sheet | `HMCommentSheet`, `.commentSheet`, shared state, `squeezeTarget` |
| Three fixed sheet positions, expanded sheet pauses, last gesture wins | `sheetMode: .snapped(squeezeFraction:)`, `HMSocialState.sheetPosition`, `snapComments(to:)`, `updateSheetSnapping(squeezedHeight:)` |
| No feed paging while the sheet is open | `allowsPagingWhileSheetOpen`, `hmFeedPagingDisabled` |
| Tap on the squeezed video closes the sheet | `closesSheetOnVideoTap` |
| Buffering, failure and tap-to-retry at the squeezed size | `showsPlaybackStatus`, `HMPlaybackStatusView`, `jump(toID:)`, `failedItemPolicy` |
| Safe sidecar, ad suppression | `.sidecar`, `hmReservedRegions`, `isFree`, `adState.isActive` |
| Horizontal letterboxing and minimal fullscreen | Player automatic presentation, independent fullscreen layout and minimal controls |
| Fullscreen controls out of the way of the video, exit always reachable | `fullscreenControls` (`.visible`, `.autoHide(after:)`, `.hidden`), the player's corner exit, VoiceOver escape |
