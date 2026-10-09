# Getting started: player with UI

Present an engagement overlay using your own interaction source.

## Install and present

Add the player repository in SwiftPM and link **both** HotMicPlayer and HotMicPlayerUI products to your iOS app. The UI product has no HotMicCore dependency.

```swift
import SwiftUI
import HotMicPlayer
import HotMicPlayerUI

@MainActor struct PartnerFeed: View {
    @State private var player = HMPlayer(interactions: MemorySource())
    let items: [HMMediaItem]
    var body: some View {
        HMVerticalFeedView(player: player, layout: HMOverlayLayout.self)
            .hmTheme(.default)
            .task { player.replaceAll(items) }
            .onDisappear { player.teardown() }
    }
}
```

`MemorySource` is your `HMInteractionSource`; a complete small implementation lives in [Examples/PlayerWithUI](https://github.com/hotmic-wp/hotmic-player-sdk/tree/main/Examples/PlayerWithUI). It provides in-memory chat, reactions and a poll and declares the supported actions. Replace it with your backend adapter when ready. The player retains the source.

## Configure the overlay

The overlay places chat, polls and metadata near the bottom, an action rail on the trailing edge, and an engagement scrubber below. A video tap toggles playback; Comment opens the composer; dragging the scrubber defers automatic failure skips. All actions follow source capabilities.

```swift
var options = HMOverlayLayout.Options()
options.chatLimit = 3
options.showsFloatingReactions = false
options.actions = [.react, .comment, .mute, .share]
options.onShare = { item in presentShareSheet(for: item) }
// Apply above the feed's layouts:
feed.hmOverlayOptions(options)
```

Share is hidden until a handler exists. Use `contentInsets` for extra host chrome beyond the feed safe area. Explicit options passed to `HMOverlayLayout(player:item:snapshot:options:)` override environment options. See <doc:Theming> for brand colors, fonts and icons.

## Own your composition

Use the overlay closure to combine your controls with individual components, or implement `HMEngagementLayout.init(context:)` to create a reusable arrangement. `HMEngagementContext` includes the player, item, snapshot, engagement, and current-cell status. Only seek or start animations while the cell is current. Custom gestures that should defer failure skips must call the player's `beginInteraction()` and `endInteraction()`.

For URL installation, playlist edits, event subscriptions and configuration, use the [player guides](https://github.com/hotmic-wp/hotmic-player-sdk/tree/main/Sources/HotMicPlayer/HotMicPlayer.docc). The [full Sample](https://github.com/hotmic-wp/hotmic-player-sdk/tree/main/Sample) adds labs and benchmark controls; its mock source requires Benchmark SPI and is not needed in partner apps.
