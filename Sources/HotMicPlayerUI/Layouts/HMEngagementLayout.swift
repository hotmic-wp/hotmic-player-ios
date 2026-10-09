#if os(iOS)
import AVFoundation
import SwiftUI
import HotMicPlayer

/// Everything a layout needs for one feed cell.
@MainActor public struct HMEngagementContext {
    /// The player that owns the item.
    public let player: HMPlayer
    /// The cell's item.
    public let item: HMMediaItem
    /// The cell's playback snapshot; `currentTime` is the engagement clock.
    public let snapshot: HMPlaybackSnapshot
    /// The item's engagement state.
    public let engagement: HMEngagement

    /// Creates a context, fetching the item's engagement state from the player.
    public init(player: HMPlayer, item: HMMediaItem, snapshot: HMPlaybackSnapshot) {
        self.init(player: player, item: item, snapshot: snapshot, engagement: player.engagement(for: item))
    }

    /// Creates a context with explicit engagement state, for previews and tests.
    public init(player: HMPlayer, item: HMMediaItem, snapshot: HMPlaybackSnapshot, engagement: HMEngagement) {
        self.player = player
        self.item = item
        self.snapshot = snapshot
        self.engagement = engagement
    }

    /// Whether this cell is the player's current item. Only the current cell animates.
    public var isCurrent: Bool { player.currentItem?.id == item.id }
    /// The playhead, in seconds of media time.
    public var mediaTime: TimeInterval { snapshot.currentTime }
}

/// A ready-made arrangement of the engagement components around one feed item.
///
/// This is the extension point for layouts. `HMOverlayLayout` is the first; a
/// layout is any view built from an `HMEngagementContext`, composed from the
/// public components, so a partner can write their own the same way:
///
/// ```swift
/// struct MyLayout: HMEngagementLayout {
///     let context: HMEngagementContext
///     init(context: HMEngagementContext) { self.context = context }
///     var body: some View {
///         HMChatRail(engagement: context.engagement, mediaTime: context.mediaTime)
///     }
/// }
/// HMVerticalFeedView(player: player, layout: MyLayout.self)
/// ```
///
/// Planned layouts and what they will add:
/// - `.stacked` (video on top, chat below) and `.sidePanel` (landscape, chat beside
///   the video) both need the *video* to give up space, which an overlay cannot do.
///   They will add a `static var videoPlacement` requirement with a default of
///   full-bleed, which `HMVerticalFeedView` will read to inset the video surface.
///   Existing layouts, including partner ones, keep compiling unchanged.
@MainActor public protocol HMEngagementLayout: View {
    /// Builds the layout for one feed cell.
    init(context: HMEngagementContext)
}

public extension HMVerticalFeedView where Overlay: HMEngagementLayout {
    /// Creates a feed whose overlay is a ready-made engagement layout:
    /// `HMVerticalFeedView(player: player, layout: HMOverlayLayout.self)`.
    init(player: HMPlayer, transition: HMPageTransition = .none, gravity: AVLayerVideoGravity = .resizeAspectFill,
         layout: Overlay.Type) {
        self.init(player: player, transition: transition, gravity: gravity) { item, snapshot in
            Overlay(context: HMEngagementContext(player: player, item: item, snapshot: snapshot))
        }
    }
}
#endif
