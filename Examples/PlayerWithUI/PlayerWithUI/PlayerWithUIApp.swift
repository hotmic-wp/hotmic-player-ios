import SwiftUI
import HotMicPlayer
import HotMicPlayerUI

@main @MainActor struct PlayerWithUIApp: App {
    var body: some Scene { WindowGroup { PlayerWithUIScreen() } }
}

@MainActor private final class PlayerWithUIOwner: ObservableObject {
    let player = HMPlayer(interactions: MemorySource())
    deinit { MainActor.assumeIsolated { player.teardown() } }
}

@MainActor struct PlayerWithUIScreen: View {
    @StateObject private var owner = PlayerWithUIOwner()
    private var player: HMPlayer { owner.player }
    private var theme: HMTheme {
        var theme = HMTheme.default
        theme.colors.accent = .orange
        theme.colors.accentSecondary = .yellow
        theme.reactionPalette = ["👏", "🔥", "💜"]
        return theme
    }
    private var options: HMOverlayLayout.Options {
        var options = HMOverlayLayout.Options()
        options.chatLimit = 3
        options.actions = [.react, .comment, .mute]
        return options
    }
    var body: some View {
        HMVerticalFeedView(player: player, layout: HMOverlayLayout.self)
            .hmTheme(theme)
            .hmOverlayOptions(options)
            .task {
                guard player.items.isEmpty else { return }
                player.replaceAll([HMMediaItem(id: "demo", url: URL(string:
                    "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!,
                    format: .hls, title: "Your brand, your engagement", author: "In-memory example")])
            }
            .onAppear { player.isFeedVisible = true }
        .onDisappear { if !player.isFullscreen { player.isFeedVisible = false } }
    }
}
