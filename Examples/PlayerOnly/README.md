# PlayerOnly

A 40-line SwiftUI app using only public HotMicPlayer API. It plays public MP4 and HLS VOD URLs and wires replace-all, replace-upcoming, insert-next, append and remove-current to buttons. Added items receive unique IDs. Swipe the horizontal button row to reach every operation; swipe the feed vertically to change media.

Open `PlayerOnly.xcodeproj`, select the **PlayerOnly** scheme and an iPhone simulator, and run. Requires Xcode 16+ and iOS 17+. The project resolves the package from this checkout; no setup, credentials or signing configuration is required for the simulator. Internet access is required for the third-party demo media. Replace those URLs with your own immutable VOD assets for an integration.

```bash
xcodebuild build -project Examples/PlayerOnly/PlayerOnly.xcodeproj -scheme PlayerOnly \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project Examples/PlayerOnly/PlayerOnly.xcodeproj -scheme PlayerOnly \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

Run these commands from the repository root. [Player guide](../../Sources/HotMicPlayer/HotMicPlayer.docc/GettingStarted.md).
