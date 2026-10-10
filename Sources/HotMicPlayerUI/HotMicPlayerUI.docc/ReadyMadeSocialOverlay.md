# Ready-made social overlay

Ship a themeable vertical-video social experience, or compose your own interface on the same public hooks.

## Choose the integration level

Use `HMSocialPlayerView` for a complete feed or inline player: metadata, ephemeral preview, Fire/Comment/Share rail, progress, caption toggle and an interactive comment sheet. `HMSocialPlayerViewController` embeds the same SwiftUI implementation in UIKit; add it as a child controller and constrain its view. Playback remains owned by your `HMPlayer`.

For custom chrome, depend only on HotMicPlayer and use `hmVideoLayout`, `HMVideoLayout.squeezeTarget`, `hmVideoGestures`, `HMHitArea`, `hmReservedRegions` and `HMOverlayRegions.isFree`. The optional kit uses those same public APIs and has no private engine access. Existing `HMOverlayLayout`, `HMChatRail` and engagement components remain available with their original initializers. `HMActionRail` has an additional backend-independent social initializer, rather than a second rail implementation.

## Data in, events out

Implement `HMSocialDataSource` on an observable main-actor model, or fill `HMSocialModel`. Its `HMSocialContent` contains title, description, community, hashtags, optional counts, viewer membership, preview candidates and loaded comments. Nil counts stay hidden. Stable comment IDs identify rows across page loads. Keep each data source alive by media item ID; update it as backend pushes arrive.

The data source owns network actions, pagination cursors, authoritative results, optimistic updates and rollback. `setReacted` receives the intended membership, `loadMoreComments` loads the next page, and `postComment` posts a draft. Throw errors to display them; failed comment submissions preserve the draft. The default sheet serializes its own page loads and submissions. `HMSocialModel` action closures must update `content` with resulting state; its defaults do not invent server success or counts.

`HMEngagementSocialAdapter` supplies this contract from `HMEngagement`, including custom backend and Connect interaction sources. It uses authoritative item summaries, independent comment pages and `sendChat`. Its `previewSelection` closure lets the host choose candidates independently of the list's paging policy. No Connect dependency is added to the UI product.

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

Each piece is usable alone: `HMMetadataView`, `HMCommentPreview`, `HMActionRail`, `HMFireBurst`, `HMProgressBar`, `HMCommentSheet` and `HMPlayPauseAffordance`. A standalone `HMSocialOverlay` needs the matching `hmSocialPlayback(player:state:options:data:callbacks:)` modifier on its ancestor feed or inline surface. Share one `HMSocialState` between them. For an inline surface already constrained inside the safe area, pass `extendsUnderSafeArea: false` to the modifier; `HMSocialPlayerView` chooses this automatically. The modifier applies video insets, interactive squeeze and public native tap recognizers; the overlay cannot change an ancestor's video layout by itself.

The host supplies navigation separately; pass only its content height, excluding system bottom safe area. Video fills the remaining viewport and shifts upward. Metadata and progress sit above navigation and outside the rail. Preview occupies its own row below the rail and above metadata. Long descriptions expand in a bounded scroll region so they cannot push controls into the notch or navigation.

Previews are visible for `previewDuration` and then disappear. `previewRotationInterval` controls the rotation period; nil shows only the first host-selected comment once per item. The kit resets selection when the current item changes and pauses previews during sheets, ads and fullscreen. Tap always opens the full sheet. Hosts can provide a single candidate and disable automatic rotation.

The default sheet supports handle dragging, accessible resizing and a close button. Every drag update changes `squeezeTarget` without changing playback. `.commentSheet { item in ... }` replaces its list/composer while retaining the sheet and squeeze shell. Replacement content owns posting and its callbacks. `.sidecar(size:) { item in ... }` supplies a fixed-size slot that is shown only if the entire rectangle passes `isFree` inside the visible video against safe area, navigation and registered controls. If no slot fits, the sidecar stays hidden. Register extra host chrome with `hmExcludedHitAreas` on the surface ancestor so it also participates. Hosts needing other placements can use the individual components and public region API.

The kit observes `adState.isActive`, including decisioning, and suppresses the rail, preview, Fire and comment trigger. An open sheet closes when an ad starts. Hosts own ad SDK skip/countdown UI. Captions use `availableCaptionLanguages` and `captionsEnabled`; CC stays hidden without tracks, and registered control bounds are reserved for caption placement. Mute is off as a control by default; audio starts on with the player's default configuration and mute state belongs to the shared player across swipes. Looping stays at the player's default; the kit never advances items on completion.

Landscape items use the player's automatic letterboxing policy. Fullscreen has independent zero-inset video layout, no navigation or social rail, and only playback, optional mute, CC and exit controls.

## Theme

Apply `.hmTheme(theme)` above the player. Existing palette, Dynamic Type fonts, SF Symbol names, corner radius and reaction palette remain source-compatible. `customImages` overrides social icons with host `Image` assets; `railSpacing`, `fireAnimationDuration` and `sheetAnimationDuration` tune layout and motion. Symbol fallbacks for captions, fullscreen, play and close are also configurable.

```swift
var theme = HMTheme.default
theme.colors.accentSecondary = .orange
theme.customImages[.fire] = Image("BrandFire")
theme.railSpacing = 12
theme.cornerRadius = 16
```

Fire taps and video double taps enter `HMSocialState.fire` and use one `HMFireBurst` event. Rail tap toggles membership; double tap adds it without undoing a previous reaction. The burst originates at the tap and resolves into the same rail icon. Reduce Motion uses a stationary highlight with no movement, and sheet transitions do not animate. The public native video element supplies a VoiceOver Fire custom action. Controls expose button labels and values, including Fire reacted/not reacted, mute and CC; text follows Dynamic Type and uses a dark scrim for contrast over video.

## Behavior mapping

| Requirement | Component / public API |
| --- | --- |
| 1.1 Persistent host navigation, video shifted upward | `hostNavigationHeight`, `hmVideoLayout` content insets |
| 1.2 Metadata, expandable description, community, hashtags and progress | `HMMetadataView`, `hashtagTapped`, `HMProgressBar` |
| 1.3 / 3.1 Ephemeral preview, no overlap, host rotation, tap to sheet | `HMCommentPreview`, preview candidates, duration/rotation options, `openComments` |
| 1.4 / 3.2 Fire/Comment/Share rail, reaction animation, native share | Existing `HMActionRail` social initializer, shared state, `HMFireBurst`, `share`, `HMShareSheet` |
| 1.5 / 2.4 Audio on, optional persistent mute | Player defaults, `showsMute`, `HMPlayer.isMuted` |
| 1.6 / 6.2 Loop without automatic advance | `HMPlayerConfiguration.loops`, no kit advancement |
| 1.7 / 3.3 Same Fire burst for surface double tap and rail | `hmVideoGestures`, `HMSocialState.fire`, registered `HMHitArea` bounds |
| 2.1 / 2.2 Tap playback, lightweight pause, visible chrome | Native tap hook, `HMPlayPauseAffordance`, resting layout |
| 2.3 Continuous progress, opt-in scrubbing | Snapshot playhead, `HMProgressBar`, `allowsScrubbing`, interaction begin/end |
| 2.6 Caption control only with tracks | `availableCaptionLanguages`, `captionsEnabled` |
| 2.7 / 3.6 Accessibility and contrast | Button labels/values, native Fire custom action, theme fonts, scrim, Reduce Motion |
| 3.4 Host-provided compact counts | Nil hides counts; `HMCountFormatter` |
| 3.5 Safe area | `hmFeedSafeArea` plus inline/fullscreen geometry safe insets |
| 4.0 Default or replacement interactive squeezed sheet | `HMCommentSheet`, `.commentSheet`, shared state, `squeezeTarget` |
| 5.1 / 5.3 Safe sidecar, ad suppression | `.sidecar`, `hmReservedRegions`, `isFree`, `adState.isActive` |
| Horizontal letterboxing and minimal fullscreen | Player automatic presentation, independent fullscreen layout and minimal controls |
