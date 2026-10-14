# Integration checklist

Prepare the host app, verify the ownership boundary and provide reproducible diagnostics.

## Host configuration

- **Deployment:** iOS 17+, Xcode 16+ / Swift 6 package tools; package sources use Swift 5 language mode. HotMicPlayerUI is iOS-only. Validate with your supported Xcode/iOS versions.
- **Orientations:** include portrait and landscape left/right in `UISupportedInterfaceOrientations` (and the iPad variant where relevant). Any app delegate mask must also allow landscape. Portrait-only apps expand fullscreen in portrait. Device-driven rotation is opt-in with `followsDeviceRotation`.
- **Audio:** decide who owns `AVAudioSession`. The default SDK session is playback/moviePlayback, audio on, no mixing. With `managesAudioSession = false`, configure and activate the host session and recover it after interruptions/resets.
- **Background:** default playback pauses in background. Only opt into `allowsBackgroundAudio` when the product needs it; the host must enable `UIBackgroundModes` → `audio` and use an appropriate session. No background mode is needed for a foreground feed.
- **Info.plist:** HTTPS VOD needs no ATS exception, microphone or camera permission. Use a narrowly scoped ATS exception only for a deliberate HTTP development origin. The SDK adds no app plist entries or signing capabilities. Ad SDKs may require their own privacy/advertising configuration; follow their documentation and your consent policy.
- **Privacy manifest:** the package bundles `PrivacyInfo.xcprivacy` for elapsed-time/timer use of SystemBootTime (`35F9.1`) and cache-file metadata within the app container (`C617.1`). Confirm inclusion in your archive’s privacy report and declare your app/ad/backend data practices separately. Keep raw `monotonicTime` on device; export elapsed durations instead of raw uptime. See [Apple’s required-reason API guidance](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons).
- **Media:** use immutable supported MP4/HLS VOD or local files, unique stable IDs and aspect hints. Check byte ranges, MIME types and <doc:EncodingForFastStart>.
- **UI:** measure persistent navigation/safe areas, reserve chrome, configure fullscreen separately, test small screens and the largest accessibility text sizes. Disable simulator hardware keyboard and verify draft/post controls above the software keyboard.
- **Services:** supply ad decisioning, consent/skip policy, backend authentication and stable engagement IDs. Advertise only supported interaction capabilities. No HotMic account is required for host URLs and backend.
- **Lifecycle:** retain players and per-item adapters; reuse an adapter only if `adapter.engagement === player.engagement(for: item)`, replacing it after engagement rebuilds. The kit gates replay sampling to the current visible overlay; custom consumers must keep a stable UUID per view instance and call `setReplayActive(false, for: token)` while hidden. Pause hidden feeds with `isFeedVisible = false`, restore it on return, and teardown only when the owner is permanently dismissed. A new screen after teardown requires a new player.

## Who owns what

| SDK owns | Host owns |
| --- | --- |
| AVFoundation playback, bounded cache/prefetch, snapshots and events | Media catalog/ranking, URL lifetime and encoding/CDN |
| Atomic playlist operations and paging coordination | Source transport, item IDs, app navigation and screen lifetime |
| Rendering geometry, native gestures, fullscreen layer transfer | Nav/control reservations, supported orientations, custom chrome |
| Kit components, default comment/squeeze shell and caption placement | Brand/theme, replacement content, share presentation, backend requests |
| Ad deadlines/state, content pause/resume, URL creative playback | Ad SDK rendering/permission response, targeting, consent, tracking and skip UI |
| Interruption/lifecycle handling, optional managed audio session | Host audio policy, session when opted out, background app capabilities |
| Nonblocking telemetry callbacks | Telemetry transport, privacy, buffering and report redaction |

## Known limitations

This delivery targets MP4 and HLS **VOD**. Live, DRM, expiring authenticated-origin renewal and advanced HLS cases are outside the supported contract. WebVTT sidecars render text safely; arbitrary cue positioning, CSS and regions are not a browser layout engine. Captions may hide when no complete cue fits outside reservations. Fullscreen is app-owned presentation, not a second playback engine.

For HotMic engagement via Connect, **per-stream reactions and paged comment history are not yet available from the HotMic backend**. A host backend gets the full feature set through `HMInteractionSource` or direct social data. Fake Connect data in the Sample demonstrates the interface, including simulated capabilities; it does not imply live service support. Install/configure the separate Connect package according to its own version compatibility and README.

## Acceptance walkthrough

Run both starters. In the Sample's Partner demo, verify mixed MP4/HLS and portrait/landscape, persistent tabs, ranked refresh, tap/double tap, both overlay paths and replacement slots, comments/paging/posting with the software keyboard, captions, mute, sidecar, fullscreen and return swipes. Exercise URL pre-roll, host-played completion/skip/cancellation, and background/foreground pause. Use the dedicated audio/captions lab for simulated interruption/route/reset notifications and the benchmark for timing. Check VoiceOver labels/actions, largest Dynamic Type and Reduce Motion.

## Report a performance problem

Use [performance interpretation](https://github.com/hotmic-wp/hotmic-player-ios/blob/main/docs/BENCHMARKING.md) with owned media and the same configuration/network/cache state for each comparison. Include attempted, started and never-started coverage alongside first-frame and moving-playback observations. The [public regression harness](https://github.com/hotmic-wp/hotmic-player-ios/blob/main/Sample/TestSupportTools/README.md) runs without a private checkout. Simulator results establish correctness; comparable device runs are needed for performance conclusions.

Include SDK commit/version, Xcode/iOS and device model, reproduction steps, configuration and workload, cache reset/warm state, media encoding/manifest characteristics, network profile, first-frame percentiles, stalls, bytes and memory. Include expected behavior, relevant player/ad events and a minimal host overlay if UI affects the result. Keep raw evidence in ignored `.bench/` locally; remove credentials, private URLs and personal data before sharing through your HotMic contact or [repository issues](https://github.com/hotmic-wp/hotmic-player-ios/issues). Connect-specific failures belong with the Connect adapter integration.

- **Optional diagnostics:** default off; verify <doc:OptionalDiagnostics>, collector deployment, cancellation/drop behavior and archive privacy report before enabling. The bundled manifest declares unlinked, nontracking optional performance/diagnostic analytics. Host analytics, advertising and backend disclosures remain the host’s responsibility.
