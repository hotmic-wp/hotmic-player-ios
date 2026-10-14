#if os(iOS)
import AVFoundation
import SwiftUI
import HotMicPlayer

/// Everything a layout needs for one feed cell.
///
/// Access on the main actor.
@MainActor public struct HMEngagementContext {
    /// The player that owns the item.
    ///
    /// Access on the main actor.
    public let player: HMPlayer
    /// The cell's item.
    ///
    /// Access on the main actor.
    public let item: HMMediaItem
    /// The cell's playback snapshot; `currentTime` is the engagement clock.
    ///
    /// Access on the main actor.
    public let snapshot: HMPlaybackSnapshot
    /// The item's engagement state.
    ///
    /// Access on the main actor.
    public let engagement: HMEngagement

    /// Creates a context, fetching the item's engagement state from the player.
    ///
    /// Access on the main actor.
    public init(player: HMPlayer, item: HMMediaItem, snapshot: HMPlaybackSnapshot) {
        self.init(player: player, item: item, snapshot: snapshot, engagement: player.engagement(for: item))
    }

    /// Creates a context with explicit engagement state, for previews and tests.
    ///
    /// Access on the main actor.
    public init(player: HMPlayer, item: HMMediaItem, snapshot: HMPlaybackSnapshot, engagement: HMEngagement) {
        self.player = player
        self.item = item
        self.snapshot = snapshot
        self.engagement = engagement
    }

    /// Whether this cell is the player's current item. Only the current cell animates.
    ///
    /// Access on the main actor.
    public var isCurrent: Bool { player.currentItem?.id == item.id }
    /// The playhead, in seconds of media time.
    ///
    /// Access on the main actor.
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
///
/// Access on the main actor.
@MainActor public protocol HMEngagementLayout: View {
    /// Builds the layout for one feed cell.
    ///
    /// Access on the main actor.
    init(context: HMEngagementContext)
}

public extension HMVerticalFeedView where Overlay: HMEngagementLayout {
    /// Creates a feed whose overlay is a ready-made engagement layout:
    /// `HMVerticalFeedView(player: player, layout: HMOverlayLayout.self)`.
    ///
    /// Access on the main actor.
    init(player: HMPlayer, transition: HMPageTransition = .none, gravity: AVLayerVideoGravity = .resizeAspectFill,
         layout: Overlay.Type) {
        self.init(player: player, transition: transition, gravity: gravity) { item, snapshot in
            Overlay(context: HMEngagementContext(player: player, item: item, snapshot: snapshot))
        }
    }
}
#endif
