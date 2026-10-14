import SwiftUI
import HotMicPlayer

/// Interactive playlist editing using public APIs and the same demo media source.
struct PlaylistLabScreen: View {
    let onBack: () -> Void
    @StateObject private var owner = DemoPlayerOwner(player: HMPlayer(configuration: HMPlayerConfiguration(startsMuted: true)))
    private var player: HMPlayer { owner.player }
    @State private var serial = 0
    @State private var seeds: [HMMediaItem] = []
    @State private var error: String?
    @Environment(\.scenePhase) private var phase
    var body: some View {
        ZStack(alignment: .bottom) {
            HMVerticalFeedView(player: player) { item, snapshot in
                VStack {
                    Text(item.title ?? item.id)
                    Text("\(snapshot.state.rawValue) · \(String(format: "%.1f", snapshot.currentTime))s").accessibilityIdentifier("lab-playback")
                    Spacer()
                }.padding(.top, 80).foregroundStyle(.white).allowsHitTesting(false)
            }
            VStack(spacing: 8) {
                HStack { Button("Back", action: onBack); Spacer(); Text("Playlist editing").bold() }
                HStack {
                    Button("Replace all") { player.replaceAll(batch()) }
                    Button("Upcoming") { player.replaceUpcoming(batch()) }
                    Button("Insert next") { player.insertNext(batch()) }.accessibilityIdentifier("lab-insert-next")
                    Button("Append") { player.append(batch()) }.accessibilityIdentifier("lab-append")
                }
                HStack {
                    Button("Remove next") { player.remove(ids: Set(player.items.dropFirst(player.activeIndex + 1).prefix(1).map(\.id))) }
                    Button("Remove current") { if let id = player.currentItem?.id { player.remove(ids: [id]) } }
                    Button("Refresh ranking") {
                        if let current = player.currentItem { player.reconcile([current] + player.items.filter { $0.id != current.id }.reversed()) }
                    }
                }
                HStack {
                    Button("Previous") { player.previous() }
                    Button(player.snapshot.state == .paused ? "Play" : "Pause") { player.togglePlayPause() }
                    Button("Seek +2s") { player.seek(to: player.snapshot.currentTime + 2) }
                    Button("Next") { player.next() }.accessibilityIdentifier("lab-next")
                }
                Text("\(player.items.count) entries · revision \(player.playlistRevision)").accessibilityIdentifier("lab-status")
                if let error { Text(error) }
                ScrollView(.horizontal) {
                    HStack { ForEach(player.items) { item in Button(item.id) { player.jump(toID: item.id) } } }
                }
            }.font(.caption).padding().background(.black.opacity(0.85)).foregroundStyle(.white).buttonStyle(.bordered)
        }.background(.black).task {
            do {
                guard seeds.isEmpty else { return }
                let source = try await DemoOptions().dataSource()
                seeds = try await source.loadPage(cursor: nil).items
                player.replaceAll(seeds); await player.start()
            } catch { self.error = error.localizedDescription }
        }
        .onChange(of: phase) { _, value in player.isFeedVisible = value == .active }
        .onAppear { player.isFeedVisible = true }
        .onDisappear { if !player.isFullscreen { player.isFeedVisible = false } }
    }
    private func batch() -> [HMMediaItem] {
        serial += 1
        return seeds.map { HMMediaItem(id: "edit-\(serial)-\($0.id)", source: $0.source, title: $0.title, durationHint: $0.durationHint, aspectRatio: $0.aspectRatio) }
    }
}
