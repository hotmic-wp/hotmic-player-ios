# Getting started: HotMic streams and engagement

Use the separate HotMicPlayerCore adapter package when content and interaction data come from HotMic.

## Package boundary

This repository supplies the player, plug-in protocols and optional UI. [HotMicPlayerCore](https://github.com/hotmic-wp/hotmic-player-core-ios) lives in another repository and binds HotMicCore content and engagement to `HMItemResolver`, `HMPlaylistSource`, and `HMInteractionSource`. Follow that package's README for its supported version, installation and adapter construction. This player release does not add live playback.

With adapters created according to that package's instructions, the player wiring is:

```swift
import HotMicPlayer
import HotMicPlayerUI

// resolver, playlistSource and interactionSource come from HotMicPlayerCore.
let player = HMPlayer(resolver: resolver, interactions: interactionSource)
player.playlistSource = playlistSource
// In your SwiftUI screen:
HMVerticalFeedView(player: player, layout: HMOverlayLayout.self)
// The feed loads the first page automatically.
```

Create and access the player and interaction source on the main actor. Do not duplicate network-session ownership in your view; follow the adapter's lifecycle contract. The player package has no dependency on HotMicCore, and URL-only partners need neither package.

The partner [README](https://github.com/hotmic-wp/hotmic-player-sdk#readme) links the adapter package. See <doc:EngagementAndCustomSources> for the shared contract and <doc:GettingStarted> for screen lifetime and event handling.
