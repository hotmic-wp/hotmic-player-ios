# Captions

Expose a CC toggle when ``HMPlayer/availableCaptionLanguages`` is nonempty. HLS legible options are discovered asynchronously using AVMediaSelection; WebVTT and CEA-608 support follows AVFoundation's support for the asset. Languages are BCP-47 tags; tracks without a tag receive a stable `und-N` identifier within that item.

```swift
let clip = HMMediaItem(id: "clip", url: mp4URL,
    captionSources: ["en": englishVTT, "es": spanishVTT])
player.replaceAll([clip, HMMediaItem(id: "hls", url: hlsURL)])
player.selectCaption("es") // enables CC, remembers language across swipes
player.captionsEnabled = false
player.captionPreference = nil // follow Closed Captions + SDH again
```

The default `captionPreference` is nil: the effective `captionsEnabled` follows MediaAccessibility's **Closed Captions + SDH** (`alwaysOn`) preference, including changes while mounted. Explicit on/off and language choices last for this player instance, across swipes and playlist changes. A missing requested language falls back to a matching base language, then the first available track. Nil language uses the system's caption language order, then the app locale. `selectCaption(nil)` enables captions and returns language selection to that policy. ``HMPlayerEvent/captionsChanged(enabled:language:)`` reports preference changes; Observation also tracks asynchronously discovered languages.

AVPlayerLayer renders HLS captions natively when there are no reservations or caption/safe-area insets. Otherwise the SDK receives timed legible output and suppresses native text, placing it in the same safe overlay used by sidecars. The overlay uses MediaAccessibility's font, relative size, foreground/background/window colors and opacity, rounded window corners and text edge preference. The sidecar reader supports timed multiline text, cue IDs and basic WebVTT tags/entities; embedded HTML, cue positioning, regions and CSS do not override the host's safe placement. It is not a full browser WebVTT layout engine.

```swift
HMVerticalFeedView(player: player) { item, snapshot in
    VStack { Spacer(); HostMetadata(item: item).hmExcludedHitArea() }
}
.hmCaptionInsets(HMVideoInsets(top: 80, bottom: 90))
.hmExcludedHitAreas([actionRailFrame])
```

The layout milestone's `HMHitArea`, `hmExcludedHitArea()` and explicit regions reserve space for both gestures and captions. Insets use surface coordinates. UIKit hosts set `HMPlayerViewController.captionInsets` and `excludedHitAreas`; those rectangles are converted from the controller's view coordinates. Native hosts should update them as chrome moves. Inline/fullscreen surfaces use their own layout and registered overlay reservations; caption edge insets carry into fullscreen. If no free rectangle can fit the complete cue, text is hidden until space becomes available; it never overlaps reserved metadata, navigation or the rail. Register every overlay that captions must avoid, including noninteractive metadata.

Sidecar downloads for current and next run alongside head preparation, independently of video activation and TTFF. They support file/HTTP/HTTPS URLs, cap each file at 512 KiB, share up to eight concurrent downloads and retain eight parsed tracks in memory. There is no disk caption cache. A failed or oversized sidecar yields no text and does not fail video; turning CC off and on retries. Caption text uses media time, so pause, seek and looping remain synchronized. Caption rendering and content controls are suppressed during pre-rolls.

The Sample's **Captions + audio** lab uses generated, owned MP4 and HLS fixtures with subtitles. See `Sample/README.md` for setup.

## Verify caption integration

1. Play an HLS item with a legible track and an MP4 item with a WebVTT sidecar. Confirm each cue appears at its media time, stays synchronized after a seek, and stops advancing while paused.
2. Toggle CC, select a language, and swipe between items. Confirm the preference persists and unavailable languages use the documented fallback.
3. Set `captionPreference` to nil, then change **Settings → Accessibility → Subtitles & Captioning → Closed Captions + SDH**. Confirm the effective caption state follows the setting. Check a larger caption style for legibility over both bright and dark video.
4. Register metadata, navigation and action-rail regions, then resize or rotate the host view. Confirm complete cues stay outside every reservation; when no region fits, text stays hidden until space returns.
