# Accessibility

Feed, inline, fullscreen and UIKit surfaces expose an active **video** accessibility element. Its label is the media title (or the host's `hmVideoGestures(accessibilityLabel:)` / `videoAccessibilityLabel` fallback). Its value includes playing/paused state, current position and duration in seconds, mute state and caption state. Offscreen video elements and content actions during ads are hidden.

VoiceOver custom actions are **Play/Pause**, **Mute/Unmute** and **Captions on/off** when tracks exist. Names update with state. A host's double-tap Fire callback adds a Fire action. Activating the video invokes the host's single-tap callback, or the default play/pause toggle. The custom Play/Pause action always controls the player directly, so replacing the tap callback does not remove accessible playback control.

A separate **Playback position** element is adjustable when the current seekable duration is known. Increment and decrement seek by ``HMAccessibility/seekStep`` (ten seconds), clamped to the seekable start and end. The same policy is used by HotMicPlayerUI's engagement scrubber. It supports the current live seek window as well as VOD. Seeking while an ad is active is suppressed.

Hosts building their own controls can use public `play()`, `pause()`, `toggleMute()`, `captionsEnabled` and `seek(to:)`, and compute the same target:

```swift
let value = player.snapshot
let target = HMAccessibility.seekTarget(position: value.currentTime,
    start: value.seekableStart, duration: value.seekableDuration, increment: true)
player.seek(to: target)
```

Host overlays remain separate accessible controls; `hmExcludedHitArea()` reserves their geometry without hiding them. Captions are not repeatedly announced by VoiceOver on cue changes. Verify the active video and adjustable position in Accessibility Inspector, including changing action names after activation and disabling actions during ads. Stable SDK identifiers are `hm-video-surface` and `hm-playback-position`.

## Verify VoiceOver integration

1. In Accessibility Inspector, select the running app and inspect the active video and **Playback position** elements. Confirm the video label uses its title and the value reports playback state, position, mute and captions. Offscreen items must not appear as duplicate controls.
2. With VoiceOver enabled, focus the video and invoke Play/Pause, Mute/Unmute and Captions on/off from the Actions rotor. Confirm playback changes and the action names and value update after each activation. Repeat with a host-supplied tap callback.
3. Focus **Playback position** and swipe up or down to adjust it. Confirm ten-second seeks, clamping at the seekable boundaries, and the same behavior on the engagement scrubber.
4. Swipe to another item and enter or leave fullscreen. Confirm focusable controls describe the active item. During an ad, confirm content playback actions and seeking are unavailable and host ad controls remain accessible.
