import SwiftUI
import HotMicPlayer

@main @MainActor struct PlayerOnlyApp: App {
    var body: some Scene { WindowGroup { PlayerOnlyScreen() } }
}

@MainActor struct PlayerOnlyScreen: View {
    @State private var player = HMPlayer()
    @State private var sequence = 0
    @State private var event = "Ready"
    private let mp4 = URL(string: "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/720/Big_Buck_Bunny_720_10s_1MB.mp4")!
    private let hls = URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!
    private var initial: [HMMediaItem] {
        [.init(id: "hls", url: hls, format: .hls), .init(id: "mp4", url: mp4, format: .mp4)]
    }
    private func extra() -> [HMMediaItem] {
        sequence += 1
        return [.init(id: "extra-\(sequence)", url: mp4, format: .mp4)]
    }
    var body: some View {
        VStack(spacing: 0) {
            HMVerticalFeedView(player: player)
            Text("\(player.items.count) items · \(event)").font(.caption).lineLimit(1)
            ScrollView(.horizontal) {
                HStack {
                    Button("Replace all") { player.replaceAll(initial) }
                    Button("Replace upcoming") { player.replaceUpcoming(extra()) }
                    Button("Insert next") { player.insertNext(extra()) }
                    Button("Append") { player.append(extra()) }
                    Button("Remove current") { if let id = player.currentItem?.id { player.remove(ids: [id]) } }
                }.buttonStyle(.bordered)
            }
        }
        .task { player.replaceAll(initial) }
        .task { for await value in player.events { event = String(describing: value) } }
        .onDisappear { player.teardown() }
    }
}
