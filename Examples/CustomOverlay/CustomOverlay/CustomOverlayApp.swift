import SwiftUI
import HotMicPlayer

@main @MainActor struct CustomOverlayApp: App {
    var body: some Scene { WindowGroup { CustomScreen() } }
}

/// Host UI links only HotMicPlayer. Replace fake comments/counts with your backend.
@MainActor struct CustomScreen: View {
    @State private var player = HMPlayer()
    @State private var sheetHeight: CGFloat = 0
    @State private var reacted = false
    @State private var draft = ""
    @State private var comments = ["Fan: What a finish!"]
    var body: some View {
        GeometryReader { geometry in
            HMVerticalFeedView(player: player) { item, snapshot in
                HostChrome(player: player, item: item, videoFrame: snapshot.videoFrame,
                    sheetHeight: $sheetHeight, reacted: $reacted, draft: $draft, comments: $comments)
            }
            .hmVideoLayout(HMVideoLayout(contentInsets: HMVideoInsets(bottom: 54),
                squeezeTarget: sheetHeight > 0 ? CGRect(x: 0, y: 0, width: geometry.size.width,
                    height: max(0, geometry.size.height - sheetHeight - 54)) : nil))
            .hmVideoGestures(isAdPlaying: player.adState.isActive,
                onTap: { player.togglePlayPause() }, onDoubleTap: { _ in reacted = true })
            .onChange(of: player.adState.isActive) { _, active in if active { sheetHeight = 0 } }
            .onChange(of: player.currentItem?.id) { _, _ in reacted = false; sheetHeight = 0 }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Text("Home · Following · Profile").frame(maxWidth: .infinity).frame(height: 54).background(.black)
            }
        }
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .task {
            player.replaceAll([.init(id: "mp4", url: URL(string:
                "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/720/Big_Buck_Bunny_720_10s_1MB.mp4")!, title: "Your next highlight", aspectRatio: 16.0 / 9),
                .init(id: "hls", url: URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!, format: .hls, title: "Full match", aspectRatio: 16.0 / 9)])
        }
        .onDisappear { player.teardown() }
    }
}

@MainActor private struct HostChrome: View {
    let player: HMPlayer
    let item: HMMediaItem
    let videoFrame: CGRect
    @Binding var sheetHeight: CGFloat
    @Binding var reacted: Bool
    @Binding var draft: String
    @Binding var comments: [String]
    @Environment(\.hmReservedRegions) private var reserved
    @Environment(\.hmFeedSafeArea) private var safe
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                // Host sidecar: check a candidate against all SDK/host reservations.
                let candidate = CGRect(x: 16, y: max(safe.top, videoFrame.minY) + 16, width: 100, height: 44)
                if sheetHeight == 0, !player.adState.isActive,
                   HMOverlayRegions.isFree(candidate, videoFrame: videoFrame,
                    in: CGRect(origin: .zero, size: geometry.size), excluding: reserved.filter {
                        abs($0.minX - candidate.minX) > 1 || abs($0.minY - candidate.minY) > 1 ||
                        abs($0.width - candidate.width) > 1 || abs($0.height - candidate.height) > 1
                    }) {
                    Text("Sidecar").frame(width: 100, height: 44).background(.indigo).hmExcludedHitArea()
                        .position(x: candidate.midX, y: candidate.midY).allowsHitTesting(false)
                }
                if !player.adState.isActive {
                    VStack(alignment: .leading) {
                        HMHitArea {
                            HStack {
                                Button(reacted ? "Fired" : "Fire") { reacted.toggle() }
                                Text(HMCountFormatter().string(from: reacted ? 1201 : 1200))
                                Button("Comments") { sheetHeight = 320 }
                                if let url = item.url { ShareLink("Share", item: url) }
                            }.frame(minHeight: 44)
                        }
                        HMHitArea {
                            VStack(alignment: .leading) {
                                Text(item.title ?? "Video").font(.headline).lineLimit(2)
                                HStack {
                                    Button(player.isMuted ? "Unmute" : "Mute") { player.toggleMute() }
                                    if !player.availableCaptionLanguages.isEmpty {
                                        Button(player.captionsEnabled ? "CC on" : "CC off") { player.captionsEnabled.toggle() }
                                    }
                                    Button(player.isFullscreen ? "Exit fullscreen" : "Fullscreen") {
                                        if player.isFullscreen { player.exitFullscreen() } else { player.enterFullscreen() }
                                    }
                                }.frame(minHeight: 44)
                            }
                        }
                    }.padding().background(.black.opacity(0.7))
                        .padding(.bottom, safe.bottom).opacity(sheetHeight == 0 ? 1 : 0)
                        .allowsHitTesting(sheetHeight == 0).accessibilityHidden(sheetHeight > 0)
                } else {
                    HMHitArea { Button("Skip ad") { player.skipAd() }.frame(minHeight: 44) }
                }
                if sheetHeight > 0 {
                    HMHitArea {
                        VStack {
                            Button("Close comments") { sheetHeight = 0 }.frame(minHeight: 44)
                            ScrollView { ForEach(comments, id: \.self) { Text($0) } }
                            HStack {
                                TextField("Add a comment", text: $draft).textFieldStyle(.roundedBorder)
                                Button("Post") { comments.append("You: " + draft); draft = "" }.disabled(draft.isEmpty)
                            }.frame(minHeight: 44)
                        }.padding().frame(height: sheetHeight).frame(maxWidth: .infinity).background(.black)
                    }
                }
            }
        }
    }
}
