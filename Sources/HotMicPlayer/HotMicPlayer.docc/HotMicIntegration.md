# Getting started: HotMic streams and engagement

The optional Connect adapter's public main branch currently requires player `from: "1.1.0-alpha.1"` and cannot resolve a player pinned to `1.0.0`. A compatible adapter release must be selected separately; compatibility with 1.0.0 is not validated. URL playback and custom backends require no HotMic account.

Use the separate HotMicPlayerConnect adapter package when content and interaction data come from HotMic.

## Package boundary

This repository supplies the player, plug-in protocols and optional UI. [HotMicPlayerConnect](https://github.com/hotmic-wp/hotmic-player-connect-ios) lives in another repository and binds HotMicCore content and engagement to the player’s public protocols: `HotMicItemResolver` implements `HMItemResolver`, `HotMicPlaylistSource` implements `HMPlaylistSource`, and `HotMicInteractionSource` implements `HMInteractionSource`. Follow that package's README for its supported version, installation and adapter construction. This player release does not add live playback.

With adapters created according to that package's instructions, the player wiring is:

```swift
import SwiftUI
import HotMicPlayer
import HotMicPlayerUI

@MainActor func hotMicFeed(resolver: any HMItemResolver,
                          playlistSource: any HMPlaylistSource,
                          interactionSource: any HMInteractionSource) -> some View {
    let player = HMPlayer(resolver: resolver, interactions: interactionSource)
    player.playlistSource = playlistSource
    // The feed loads the first page automatically.
    return HMVerticalFeedView(player: player, layout: HMOverlayLayout.self)
}
```

Retain the player for the screen’s lifetime and call `teardown()` only when its owner is permanently dismissed, as in <doc:GettingStarted>. Create and access the player and interaction source on the main actor. Do not duplicate network-session ownership in your view; follow the adapter's lifecycle contract. The player package has no dependency on HotMicCore, and URL-only partners need neither package.

The partner [README](https://github.com/hotmic-wp/hotmic-player-ios#readme) links the adapter package. See <doc:EngagementAndCustomSources> for the shared contract and <doc:GettingStarted> for screen lifetime and event handling.
