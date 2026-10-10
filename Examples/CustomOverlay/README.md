# CustomOverlay

Open `CustomOverlay.xcodeproj`, select the `CustomOverlay` scheme and run on an iOS 17+ simulator. It builds the repository sources with HotMicPlayer only, fake social data and public sample video URLs. No credentials or backend are required.

Copy the app file into your app target and replace the media and callbacks with your service. Keep one player for the screen lifetime; use `isFeedVisible` for temporary hiding and terminal `teardown()` only when its owner is released. For app integration, pin the repository URL to a reviewed revision or release tag as shown in the guide. Each starter is one screen and under 200 lines of host code. The two paths use the same feed, layout, gestures and ad state. See the [Partner integration guide](../../Sources/HotMicPlayer/HotMicPlayer.docc/PartnerIntegrationGuide.md).
