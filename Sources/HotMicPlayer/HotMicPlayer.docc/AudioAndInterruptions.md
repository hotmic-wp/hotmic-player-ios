# Audio and interruptions

Audio is on by default (`startsMuted = false`). The SDK's managed audio session uses `.playback` with `.moviePlayback`: sound plays with the silent switch on and other apps' nonmixing audio is interrupted. No mixing or ducking option is requested. Muting only changes the player; it does not change the host's session category.

Set `configuration.managesAudioSession = false` before starting if the host owns audio. The SDK then observes lifecycle notifications and pauses/resumes its players, but never configures, activates or deactivates AVAudioSession. The host must configure and reactivate its session when appropriate. See Apple's [audio interruption guidance](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions).

Each notification is forwarded through ``HMPlayerEvent/audioSession(_:)``:

- Interruption began: pause content and URL ads, revoke host-ad playback permission and remember playback intent, including loading or temporarily hidden media. Suspension-only began notifications are ignored because they do not have a matching end.
- Interruption ended: resume only with `shouldResume`, retained playback intent and a visible feed. A user pause or removed output route cancels automatic resume. An unrelated end notification changes no intent.
- Route changed: publish the raw AVAudioSession reason; `oldDeviceUnavailable` pauses without automatic resume, so unplugging headphones does not play through speakers.
- Entered background: pause unless `configuration.allowsBackgroundAudio` is true. Content and URL-ad players use `.continuesIfPossible` when opted in. Opting in also requires the host's Audio background mode and appropriate session configuration; the SDK does not add entitlements or background modes.
- Entered foreground: resume only with retained playback intent and a visible surface. Loading and temporarily hidden media keep their intent. Foreground activation clears an interruption whose end was never delivered and reactivates managed audio.
- Media services reset: reconfigure the managed session and rebuild native playback objects, retaining caption/mute preferences and the current playhead. An active ad ends as failed. A paused player stays paused.

`isFeedVisible` describes host presentation, independently of application activation. Set it false when dismissing/hiding the feed and true when presenting it. Application background notifications already manage suspension. Do not equate visibility with `scenePhase` when opting into background audio. Explicit `play()` or a new playback request clears the interruption gate and reactivates managed audio, allowing recovery when the system does not deliver an interruption end.

```swift
Task { @MainActor in
    for await event in player.events {
        if case .audioSession(let change) = event { hostControls.update(change) }
    }
}
```

The Sample lab has Debug-only controls and a Documents command path for posting interruption/route/reset notifications. These exercise the SDK handler; they do not create a real phone call, unplug hardware or reset the simulator's media server.
