# Captions

Expose a CC toggle when ``HMPlayer/availableCaptionLanguages`` is nonempty. HLS legible options are discovered asynchronously using AVMediaSelection; WebVTT and CEA-608 support follows AVFoundation's support for the asset. Languages are BCP-47 tags; tracks without a tag receive a stable `und-N` identifier within that item.

Only declared tracks are listed. A multivariant playlist whose `EXT-X-STREAM-INF` tags omit `CLOSED-CAPTIONS` makes AVFoundation offer one closed-caption option with no language (CEA-608 may or may not be in the video); the SDK does not count it, so such a stream shows no control. Declare CEA-608 captions with an `EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS` rendition that carries `LANGUAGE`, and write `CLOSED-CAPTIONS=NONE` on every variant of a stream without captions, which also keeps other players from offering an empty option. Subtitle renditions and sidecars count with or without a language; forced-only subtitles never do.

```swift
let clip = HMMediaItem(id: "clip", url: mp4URL,
    captionSources: ["en": englishVTT, "es": spanishVTT])
player.replaceAll([clip, HMMediaItem(id: "hls", url: hlsURL)])
player.selectCaption("es") // enables CC, remembers language across swipes
player.captionsEnabled = false
player.captionPreference = nil // follow Closed Captions + SDH again
```

The default `captionPreference` is nil: the effective `captionsEnabled` follows MediaAccessibility's **Closed Captions + SDH** (`alwaysOn`) preference, including changes while mounted. Explicit on/off and language choices last for this player instance, across swipes and playlist changes. A requested language falls back only to a matching base language; an unavailable language never selects an unrelated or forced-only track. Forced-only HLS subtitles matching the current audio language remain selected when CC is off. Nil language uses the system's caption language order, then the app locale. `selectCaption(nil)` enables captions and returns language selection to that policy. ``HMPlayerEvent/captionsChanged(enabled:language:)`` reports preference changes; Observation also tracks asynchronously discovered languages.

AVPlayerLayer renders HLS captions natively when there are no reservations or caption/safe-area insets. Otherwise the SDK receives timed legible output and suppresses native text, placing it in the same safe overlay used by sidecars. The overlay uses MediaAccessibility's font, relative size, foreground/background/window colors and opacity, rounded window corners and text edge preference. The sidecar reader supports timed multiline text, cue IDs and basic WebVTT tags/entities; embedded HTML, cue positioning, regions and CSS do not override the host's safe placement. It is not a full browser WebVTT layout engine.

```swift
HMVerticalFeedView(player: player) { item, snapshot in
    VStack { Spacer(); HostMetadata(item: item).hmExcludedHitArea() }
}
.hmCaptionInsets(HMVideoInsets(top: 80, bottom: 90))
.hmExcludedHitAreas([actionRailFrame])
```

The layout milestone's `HMHitArea`, `hmExcludedHitArea()` and explicit regions reserve space for both gestures and captions. Insets use surface coordinates. UIKit hosts set `HMPlayerViewController.captionInsets` and `excludedHitAreas`; those rectangles are converted from the controller's view coordinates. Native hosts should update them as chrome moves. Inline/fullscreen surfaces use their own layout and registered overlay reservations; caption edge insets carry into fullscreen. If no free rectangle can fit the complete cue, text is hidden until space becomes available; it never overlaps reserved metadata, navigation or the rail. Register every overlay that captions must avoid, including noninteractive metadata.

With CC enabled, downloads for the selected sidecar language on current and next run alongside head preparation, independently of video activation and TTFF. They support file/HTTP/HTTPS URLs, cap each file at 512 KiB, cap speculative downloads at eight while always admitting a selected track and retain eight parsed tracks in memory. There is no disk caption cache. A failed or oversized sidecar yields no text and does not fail video. Failures are cached for sixty seconds to avoid repeated requests on window refresh; a later selection or attachment can retry after that interval. Caption text uses media time, so pause, seek and looping remain synchronized. Caption rendering and content controls are suppressed during pre-rolls.

The Sample's **Captions + audio** lab uses generated, owned MP4 and HLS fixtures with subtitles. See `Sample/README.md` for setup.

## Verify caption integration

1. Play an HLS item with a legible track and an MP4 item with a WebVTT sidecar. Confirm each cue appears at its media time, stays synchronized after a seek, and stops advancing while paused.
2. Toggle CC, select a language, and swipe between items. Confirm the preference persists and unavailable languages use the documented fallback.
3. Set `captionPreference` to nil, then change **Settings → Accessibility → Subtitles & Captioning → Closed Captions + SDH**. Confirm the effective caption state follows the setting. Check a larger caption style for legibility over both bright and dark video.
4. Register metadata, navigation and action-rail regions, then resize or rotate the host view. Confirm complete cues stay outside every reservation; when no region fits, text stays hidden until space returns.
