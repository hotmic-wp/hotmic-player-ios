import SwiftUI
import HotMicPlayer
import HotMicPlayerUI

@main @MainActor struct ReadyMadeOverlayApp: App {
    var body: some Scene { WindowGroup { ReadyMadeScreen() } }
}

@MainActor struct ReadyMadeScreen: View {
    @State private var player = HMPlayer()
    @State private var state = HMSocialState()
    @State private var social = HMSocialModel(content: .init(title: "Your next highlight",
        description: "Fake engagement; replace these actions with your backend.",
        hashtags: ["Highlights"], fireCount: 1200, commentCount: 1,
        comments: [.init(id: "one", author: "Fan", text: "What a finish!")]))
    @State private var shareItem: HMMediaItem?
    @State private var notice = ""
    private var options: HMSocialOptions {
        var value = HMSocialOptions(); value.showsMute = true; return value
    }
    private var callbacks: HMSocialCallbacks {
        var value = HMSocialCallbacks()
        value.share = { shareItem = $0 }
        value.sheetChanged = { _, open in notice = open ? "Comments opened" : "Comments closed" }
        value.commentPosted = { _, _ in notice = "Comment saved by host" }
        return value
    }
    var body: some View {
        HMVerticalFeedView(player: player) { item, snapshot in
            HMSocialOverlay(player: player, item: item, snapshot: snapshot, data: social,
                state: state, options: options, callbacks: callbacks)
        }
            .hmSocialPlayback(player: player, state: state, options: options, data: { _ in social }, callbacks: callbacks)
            .overlay(alignment: .top) { Text(notice).padding().allowsHitTesting(false) }
            .sheet(item: $shareItem) { item in if let url = item.url { HMShareSheet(items: [url]) } }
            .task {
                social.onSetReacted = { reacted in
                    if social.content.isReacted != reacted {
                        social.content.fireCount = (social.content.fireCount ?? 0) + (reacted ? 1 : -1)
                        social.content.isReacted = reacted
                    }
                }
                social.onPost = { text in
                    social.content.comments.append(.init(id: UUID().uuidString, author: "You", text: text))
                    social.content.commentCount = social.content.comments.count
                }
                player.replaceAll([.init(id: "mp4", url: URL(string:
                    "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/720/Big_Buck_Bunny_720_10s_1MB.mp4")!, aspectRatio: 16.0 / 9),
                    .init(id: "hls", url: URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!, format: .hls, aspectRatio: 16.0 / 9)])
            }
            .onDisappear { player.teardown() }
    }
}
