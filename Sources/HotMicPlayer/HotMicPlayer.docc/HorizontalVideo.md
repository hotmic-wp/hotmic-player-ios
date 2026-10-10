# Horizontal video

Mix portrait and landscape VOD in the feed, or embed a regular inline player.

## Aspect and presentation

`HMMediaItem.aspectRatio` is an optional display width / height hint. Supply `16.0 / 9.0` for a landscape clip or pre-roll to get the right first paint before decoding. A prepared node loads the video track's `naturalSize` and `preferredTransform` while warming; `AVPlayerItem.presentationSize` supplies the decoded display size and takes precedence. This handles camera rotation metadata and HLS rendition changes. `snapshot(for:)` exposes the aspect for prepared neighbours as well as current; unprepared items expose their hint.

Choose `HMPlayerConfiguration.presentation`, with an optional `HMMediaItem.presentation` override:

| Policy | Behavior |
| --- | --- |
| `.automatic` (default) | Fill if the relative aspect difference from the host is at most `aspectRatioTolerance` (default 0.25); otherwise fit. Unknown aspect fills until a hint or decoded size arrives. |
| `.fill` | Crop to fill the host, preserving the video's aspect. |
| `.fit` | Show the entire video with black bars. |
| `.fitWithBlurredBackdrop` | Fit over a blurred, darkened scale-to-fill poster. Without a poster, capture one small still from the existing decoded output. The backdrop is a still, with no second player or decoder. |
| `.fitWithColor` | Fit over `configuration.backdropColor`, a portable RGBA value. |

Changing policy updates layout and layer gravity without replacing the player or seeking. Existing feed calls remain source compatible. An explicit `gravity:` argument remains an override; omit it to use the new policy. Default automatic presentation intentionally changes mismatched media, including horizontal pre-rolls, from cropped to letterboxed. Matching vertical media still fills.

Overlay closures receive `snapshot.videoFrame`, a rectangle in the page's coordinates that excludes the bars when fitting. Use it to align captions or place controls outside the video. For a custom host, call `player.videoFrame(for: item, in: hostBounds)` with the actual host bounds. Snapshots obtained outside a view have no layout and return `.zero` for `videoFrame`.

```swift
var configuration = HMPlayerConfiguration()
configuration.presentation = .fitWithBlurredBackdrop
configuration.followsDeviceRotation = true
let player = HMPlayer(configuration: configuration)
player.replaceAll([
    HMMediaItem(id: "portrait", url: portraitURL, aspectRatio: 9.0 / 16.0),
    HMMediaItem(id: "landscape", url: landscapeURL, posterURL: posterURL, aspectRatio: 16.0 / 9.0)
])
```

## Fullscreen in SwiftUI

Present `HMVerticalFeedView(player:)` or `HMPlayerView(player:)` and call `player.enterFullscreen()` / `player.exitFullscreen()`. Observe `player.isFullscreen`. The view presents a fullscreen controller in its own window scene, moving the same node's video layer. Playback, playhead, first-frame timing and activation ID continue unchanged. Feed swiping is disabled until exit, which restores the selected page. Entering fullscreen cancels any pending page request and anchors the feed to the active item. The fullscreen surface includes an exit button.

Set `configuration.followsDeviceRotation = true` to enter fullscreen when a landscape active item rotates to landscape, and exit when the device returns to portrait. Face-up, face-down and unknown orientations are ignored. Rotation following is off by default. There should be one mounted playback surface per player; switch surfaces instead of mounting feed and inline views simultaneously.

```swift
HMVerticalFeedView(player: player) { item, snapshot in
    VStack {
        Spacer()
        Button("Fullscreen") { player.enterFullscreen() }
    }
}
```

## Standalone player and UIKit

`HMPlayerView(player:)` is a non-paging surface whose default inline aspect is 16:9. It uses the same `HMPlayer`, cache, adaptive prefetch and warm-next node as the feed. Pass one item or a playlist to the player. Use `next()` / `previous()` to navigate the playlist; set `configuration.loops`, `player.isMuted` and `seek(to:)` as usual. No swipe paging or automatic playlist advance is added. Pass `aspectRatio: nil` and a frame to let the host choose any size.

```swift
HMPlayerView(player: player)
    .frame(maxWidth: .infinity)
// Or: HMPlayerView(player: player, aspectRatio: nil).frame(height: 240)
```

UIKit hosts embed `HMPlayerViewController(player:)` as a child and constrain its view. The inline content defaults to 16:9; pass `aspectRatio: nil` to fill arbitrary host bounds. Its view's size is entirely host controlled:

```swift
let video = HMPlayerViewController(player: player)
addChild(video)
view.addSubview(video.view)
video.view.translatesAutoresizingMaskIntoConstraints = false
NSLayoutConstraint.activate([
    video.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
    video.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    video.view.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    video.view.heightAnchor.constraint(equalTo: video.view.widthAnchor, multiplier: 9.0 / 16.0)
])
video.didMove(toParent: self)
// The same API enters/exits fullscreen:
player.enterFullscreen()
```

For a UIKit feed, embed `UIHostingController(rootView: HMVerticalFeedView(player: player))` with the same child-controller lifecycle. Controls stay in the host; fullscreen presentation is built in. Keep `isFeedVisible` aligned with screen visibility and scene activity. Call `teardown()` only when the playback screen is permanently dismissed, not when it enters fullscreen.

## Host orientation setup

On iOS the host app must allow portrait, landscape left and landscape right in its target's Supported Interface Orientations (`UISupportedInterfaceOrientations`; also the iPad key when applicable). Any app delegate orientation mask or enclosing custom controller must allow those orientations. HotMicPlayer requests landscape geometry for a landscape fullscreen item, and restores the prior orientation on API exit (portrait on portrait device rotation). iOS decides whether to grant geometry requests; the SDK cannot override a host restriction. Fullscreen still expands within the allowed orientation if rotation is denied. Device-rotation following is iOS-only; tvOS can use the explicit fullscreen API.

The Sample's `HorizontalLabScreen` demonstrates a mixed feed, every presentation policy, overlay video bounds and an inline player. Launch with `--hm-horizontal-lab 1 --hm-manifest-url <mixed-orientation.json>` after generating your own fixtures. See the repository's Benchmarking guide for smoke commands and per-orientation reporting.
