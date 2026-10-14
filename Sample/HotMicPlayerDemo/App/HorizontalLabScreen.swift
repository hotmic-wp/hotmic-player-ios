import SwiftUI
import HotMicPlayer

/// Public-only host example: the same player survives inline/feed/fullscreen presentation.
struct HorizontalLabScreen: View {
    let onBack: () -> Void
    @StateObject private var owner: DemoPlayerOwner
    private var player: HMPlayer { owner.player }
    init(onBack: @escaping () -> Void) {
        self.onBack = onBack
        var configuration = HMPlayerConfiguration(startsMuted: true)
        configuration.presentation = .fitWithBlurredBackdrop
        configuration.followsDeviceRotation = true
        _owner = StateObject(wrappedValue: DemoPlayerOwner(player: HMPlayer(configuration: configuration)))
    }
    @State private var inline = false
    @State private var error: String?
    @Environment(\.scenePhase) private var phase
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if inline { HMPlayerView(player: player) { _, _ in caption } }
            else { HMVerticalFeedView(player: player) { _, _ in caption } }
            VStack {
                Button("Back", action: onBack)
                Spacer()
                if let error { Text(error) }
                HStack {
                    Button("Previous") { player.previous() }
                    Button("Next") { player.next() }
                    Button("Fullscreen") { player.enterFullscreen() }
                    Button(inline ? "Feed" : "Inline") { inline.toggle() }
                }
            }.padding().buttonStyle(.bordered).foregroundStyle(.white)
        }.task {
            do { if player.items.isEmpty { player.playlistSource = try await DemoOptions().dataSource() }; await player.start() }
            catch { self.error = error.localizedDescription }
        }
        .onChange(of: phase) { _, value in player.isFeedVisible = value == .active }
        .onAppear { player.isFeedVisible = true }
        .onDisappear { if !player.isFullscreen { player.isFeedVisible = false } }
    }
    private var caption: some View {
        VStack { Spacer(); Text(player.currentItem?.title ?? "Horizontal video").padding().background(.black.opacity(0.5)) }
            .allowsHitTesting(false)
    }
}
