import SwiftUI
@_spi(Benchmark) import HotMicPlayer
import HotMicPlayerUI

/// Everything drawn on top of one feed cell: the public `HMOverlayLayout`, plus
/// the demo's debug HUD. The chat rail, poll card, reactions, action rail,
/// composer and scrubber that used to live in this folder are now the
/// `HotMicPlayerUI` components, fed by the mock interaction source.
struct FeedOverlayView: View {

    let controller: HMPlayer
    let item: HMMediaItem
    let snapshot: HMPlaybackSnapshot
    let settings: DemoSettings
    let onShare: (HMMediaItem) -> Void

    @Environment(\.hmFeedSafeArea) private var safeArea

    private var isActive: Bool { controller.currentItem?.id == item.id }

    private var options: HMOverlayLayout.Options {
        var options = HMOverlayLayout.Options()
        options.onShare = onShare
        if !settings.showsOverlays {
            // Video-only mode keeps playback controls and the scrubber.
            options.showsChat = false
            options.showsPolls = false
            options.showsFloatingReactions = false
            options.actions = [.mute]
        }
        return options
    }

    var body: some View {
        ZStack {
            HMOverlayLayout(player: controller, item: item, snapshot: snapshot, options: options)

            #if DEBUG
            if isActive && BenchmarkOptions().values["moderation"] == "1" {
                VStack {
                    ModerationDebugView(engagement: controller.engagement(for: item), mediaTime: snapshot.currentTime,
                                        player: controller, session: settings.moderation)
                    Spacer()
                }
                .padding(.top, safeArea.top + 48)
                .padding(.horizontal, 12)
            }
            #endif

            if settings.showsHUD && isActive {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        // Tapping the panel dismisses it — the same instinct
                        // most people have before they find the toolbar toggle.
                        DebugHUDView(
                            snapshot: snapshot,
                            poolBusy: controller.preparedItemCount,
                            poolSize: controller.configuration.poolSize,
                            prefetchLabel: settings.prefetch.displayName
                        )
                        .contentShape(.rect)
                        .onTapGesture { settings.showsHUD = false }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, safeArea.top + 92)
                .transition(.opacity)
            }
        }
    }
}
