# CustomOverlay

Open `CustomOverlay.xcodeproj`, select the `CustomOverlay` scheme and run on an iOS 17+ simulator. It uses the local package, HotMicPlayer only, fake social data and public sample video URLs. No credentials or backend are required.

Copy the app file into your app target and replace the media and callbacks with your service. Keep one player for the screen lifetime; teardown is terminal. Each starter is one screen and under 200 lines of host code. The two paths use the same feed, layout, gestures and ad state. See the [Partner integration guide](../../Sources/HotMicPlayer/HotMicPlayer.docc/PartnerIntegrationGuide.md).
