import SwiftUI
import HotMicPlayer
import HotMicPlayerUI

@main @MainActor struct ReadyMadeOverlayApp: App {
    var body: some Scene { WindowGroup { ReadyMadeScreen() } }
}

@MainActor private final class ReadyMadeOwner: ObservableObject {
    let player = HMPlayer()
    private var models: [String: HMSocialModel] = [:]
    init() {
        player.replaceAll([
            .init(id: "hls", url: URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!, format: .hls, title: "Full match", aspectRatio: 16.0 / 9),
            .init(id: "mp4", url: URL(string: "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/720/Big_Buck_Bunny_720_10s_1MB.mp4")!, format: .mp4, title: "Your next highlight", aspectRatio: 16.0 / 9)
        ])
    }
    func data(for item: HMMediaItem) -> HMSocialModel {
        if let model = models[item.id] { return model }
        let model = HMSocialModel(content: .init(title: item.title ?? "Video",
            description: "Fake engagement; replace these actions with your backend.", hashtags: ["Highlights"],
            fireCount: 1200, commentCount: 1, comments: [.init(id: "\(item.id)-one", author: "Fan", text: "What a finish!")]))
        model.onSetReacted = { [weak model] reacted in
            guard let model, model.content.isReacted != reacted else { return }
            model.content.fireCount = (model.content.fireCount ?? 0) + (reacted ? 1 : -1)
            model.content.isReacted = reacted
        }
        model.onPost = { [weak model] text in
            guard let model else { return }
            model.content.comments.append(.init(id: UUID().uuidString, author: "You", text: text))
            model.content.commentCount = model.content.comments.count
        }
        models[item.id] = model
        return model
    }
    // Terminal cleanup belongs to the owner lifetime, not a tab's onDisappear.
    deinit { MainActor.assumeIsolated { player.teardown() } }
}

@MainActor struct ReadyMadeScreen: View {
    @StateObject private var owner = ReadyMadeOwner()
    @State private var shareItem: HMMediaItem?
    @State private var notice = ""
    private let options: HMSocialOptions = { var value = HMSocialOptions(); value.showsMute = true; return value }()
    var body: some View {
        var callbacks = HMSocialCallbacks()
        callbacks.share = { shareItem = $0 }
        callbacks.sheetChanged = { _, open in notice = open ? "Comments opened" : "Comments closed" }
        callbacks.commentPosted = { _, _ in notice = "Comment saved by host" }
        // Standalone HMSocialOverlay + hmSocialPlayback is available for existing host surfaces.
        return HMSocialPlayerView(player: owner.player, options: options, callbacks: callbacks, data: owner.data)
            .overlay(alignment: .top) { Text(notice).padding().allowsHitTesting(false) }
            .sheet(item: $shareItem) { item in if let url = item.url { HMShareSheet(items: [url]) } }
            .onAppear { owner.player.isFeedVisible = true }
            .onDisappear { owner.player.isFeedVisible = false }
    }
}
