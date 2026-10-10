import SwiftUI
import UIKit
import HotMicPlayer

@main @MainActor struct CustomOverlayApp: App {
    var body: some Scene { WindowGroup { CustomScreen() } }
}

@MainActor private final class CustomOwner {
    let player = HMPlayer(interactions: FakeComments())
    init() {
        player.replaceAll([
            .init(id: "mp4", url: URL(string: "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/720/Big_Buck_Bunny_720_10s_1MB.mp4")!, title: "Your next highlight", aspectRatio: 16.0 / 9),
            .init(id: "hls", url: URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!, format: .hls, title: "Full match", aspectRatio: 16.0 / 9)
        ])
    }
    deinit { MainActor.assumeIsolated { player.teardown() } }
}

/// Host UI links only HotMicPlayer. Its backend and styling are independent of the optional kit.
@MainActor struct CustomScreen: View {
    @State private var owner = CustomOwner()
    @State private var sheetHeight: CGFloat = 0
    @State private var keyboard: CGFloat = 0
    private var player: HMPlayer { owner.player }
    var body: some View {
        GeometryReader { geometry in
            let safe = geometry.safeAreaInsets
            let fullHeight = geometry.size.height + safe.top + safe.bottom
            HMVerticalFeedView(player: player) { item, snapshot in
                HostChrome(player: player, item: item, videoFrame: snapshot.videoFrame,
                    sheetHeight: $sheetHeight, keyboard: keyboard).id(item.id)
            }
            .hmVideoLayout(HMVideoLayout(contentInsets: HMVideoInsets(bottom: 54),
                squeezeTarget: sheetHeight > 0 ? CGRect(x: 0, y: safe.top, width: geometry.size.width,
                    height: max(0, fullHeight - safe.top - safe.bottom - 54 - sheetHeight - keyboard)) : nil))
            .hmVideoGestures(isAdPlaying: player.adState.isActive, onTap: { player.togglePlayPause() }, onDoubleTap: { _ in
                if let item = player.currentItem { Task { try? await player.engagement(for: item).setReaction("🔥", reacted: true) } }
            })
            .onChange(of: player.adState.isActive) { _, active in if active { sheetHeight = 0 } }
            .onChange(of: player.currentItem?.id) { _, _ in sheetHeight = 0 }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Text("Home · Following · Profile").frame(maxWidth: .infinity).frame(height: 54).background(.black)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
                let screenBottom = geometry.frame(in: .global).maxY + safe.bottom
                keyboard = max(0, screenBottom - end.minY - safe.bottom - 54)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboard = 0 }
        }
        .ignoresSafeArea(.keyboard).foregroundStyle(.white).preferredColorScheme(.dark)
        .onAppear { player.isFeedVisible = true }
        .onDisappear { player.isFeedVisible = false }
    }
}

@MainActor private struct HostChrome: View {
    let player: HMPlayer
    let item: HMMediaItem
    let videoFrame: CGRect
    @Binding var sheetHeight: CGFloat
    let keyboard: CGFloat
    @State private var draft = ""
    @State private var error: String?
    @Environment(\.hmReservedRegions) private var reserved
    @Environment(\.hmFeedSafeArea) private var safe
    private var engagement: HMEngagement { player.engagement(for: item) }
    private var open: Bool { sheetHeight > 0 && player.currentItem?.id == item.id }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom).allowsHitTesting(false)
                let candidate = CGRect(x: 16, y: max(safe.top, videoFrame.minY) + 16, width: 100, height: 44)
                if !open, !player.adState.isActive,
                   HMOverlayRegions.isFree(candidate, videoFrame: videoFrame, in: CGRect(origin: .zero, size: geometry.size),
                    excluding: reserved.filter { $0 != candidate }) {
                    Text("Sidecar").frame(width: 100, height: 44).background(.indigo).hmExcludedHitArea()
                        .position(x: candidate.midX, y: candidate.midY).allowsHitTesting(false)
                }
                if !player.adState.isActive && !open {
                    HMHitArea {
                        VStack(spacing: 12) {
                            Button { Task { try? await engagement.setReaction("🔥", reacted: !(engagement.reactionSummary(for: "🔥")?.reactedByViewer ?? false)) } } label: {
                                HostActionLabel(symbol: "flame.fill", title: "Fire", detail: HMCountFormatter().string(from: engagement.reactionSummary(for: "🔥")?.count ?? 0))
                                    .foregroundStyle(engagement.reactionSummary(for: "🔥")?.reactedByViewer == true ? .orange : .white)
                            }
                            Button { sheetHeight = 320 } label: { HostActionLabel(symbol: "bubble.right.fill", title: "Comments", detail: "\(engagement.commentCount ?? 0)") }
                            if let url = item.url { ShareLink(item: url) { HostActionLabel(symbol: "arrowshape.turn.up.right.fill", title: "Share") } }
                        }.padding(10).background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 24))
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(.trailing, 16).padding(.bottom, safe.bottom + 190)
                    HMHitArea {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("HIGHLIGHTS").font(.caption2.bold()).tracking(2).padding(6).background(.indigo, in: Capsule())
                            Text(item.title ?? "Video").font(.title2.bold()).lineLimit(2)
                            Text("The plays worth watching again.").font(.subheadline).lineLimit(2)
                            HStack(spacing: 8) {
                                control(player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", label: "Toggle mute") { player.toggleMute() }
                                if !player.availableCaptionLanguages.isEmpty { control("captions.bubble", label: "Toggle captions") { player.captionsEnabled.toggle() } }
                                control("arrow.up.left.and.arrow.down.right", label: "Fullscreen") {
                                    if player.isFullscreen { player.exitFullscreen() } else { player.enterFullscreen() }
                                }
                            }
                        }.frame(maxWidth: max(0, geometry.size.width - 116), alignment: .leading)
                    }.padding(16).padding(.bottom, safe.bottom)
                } else if player.adState.isActive {
                    // Demo policy: real hosts must use their SDK's skip eligibility.
                    HMHitArea { Button("Skip ad") { player.skipAd() }.frame(minHeight: 44)
                        .disabled(player.adProgress.elapsed < 3 || !isPlayingAd) }.padding(.bottom, safe.bottom)
                }
                if open && !player.adState.isActive {
                    HMHitArea {
                        VStack {
                            Button("Close comments") { sheetHeight = 0 }.frame(minHeight: 44)
                            ScrollView { ForEach(engagement.comments(near: 0)) { Text("\($0.author): \($0.text)").frame(maxWidth: .infinity, alignment: .leading) } }
                            if let error { Text(error).font(.caption) }
                            HStack {
                                TextField("Add a comment", text: $draft).textFieldStyle(.roundedBorder)
                                Button("Post") { Task {
                                    do { try await engagement.sendChat(draft); draft = ""; error = nil }
                                    catch { self.error = error.localizedDescription }
                                } }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }.frame(minHeight: 44)
                        }.padding().frame(height: sheetHeight).frame(maxWidth: .infinity).background(.black)
                    }.padding(.bottom, safe.bottom + keyboard).task { try? await engagement.loadComments() }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }
    private var isPlayingAd: Bool { if case .playing = player.adState { return true }; return false }
    private func control(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 44, height: 44).background(.white.opacity(0.12), in: Circle()) }.accessibilityLabel(label)
    }
}

private struct HostActionLabel: View {
    let symbol: String
    let title: String
    var detail: String? = nil
    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).frame(width: 44, height: 44)
            Text(title).font(.caption2.bold()).lineLimit(1)
            if let detail { Text(detail).font(.caption2.monospacedDigit()).lineLimit(1) }
        }.frame(width: 64)
    }
}

/// In-memory service: HMEngagement owns per-item optimism and pending comments.
@MainActor private final class FakeComments: HMInteractionSource {
    private var fires: [String: HMItemReactionSummary] = [:]
    private var history: [String: [HMTimelineEvent]] = [:]
    private var loaded: [String: () -> HMEngagement?] = [:]
    func timeline(for item: HMMediaItem) -> HMStreamTimeline { EmptyTimeline() }
    func capabilities(for item: HMMediaItem) -> HMEngagementCapabilities { [.toggleReaction, .loadComments, .sendChat] }
    func engagementDidLoad(_ engagement: HMEngagement) {
        loaded[engagement.item.id] = { [weak engagement] in engagement }
        engagement.updateReactionSummary(fires[engagement.item.id] ?? .init(count: 1200, reactedByViewer: false), for: "🔥")
        engagement.updateCommentCount(rows(engagement.item).count)
    }
    func setReaction(_ emoji: String, isReacted: Bool, for item: HMMediaItem) async throws -> HMItemReactionSummary {
        let old = fires[item.id] ?? .init(count: 1200, reactedByViewer: false)
        let value = HMItemReactionSummary(count: old.count + (old.reactedByViewer == isReacted ? 0 : isReacted ? 1 : -1), reactedByViewer: isReacted)
        fires[item.id] = value; return value
    }
    func comments(for item: HMMediaItem, before cursor: String?) async throws -> HMCommentPage {
        .init(comments: rows(item), olderCursor: nil, totalCount: rows(item).count)
    }
    func sendChat(_ message: HMChatMessage, for item: HMMediaItem) async throws -> HMTimelineEvent? {
        let event = HMTimelineEvent(id: UUID().uuidString, offset: 0, kind: .chat, author: "You", text: message.text)
        history[item.id] = rows(item) + [event]
        loaded[item.id]?()?.updateCommentCount(rows(item).count)
        return event
    }
    private func rows(_ item: HMMediaItem) -> [HMTimelineEvent] {
        history[item.id] ?? [.init(id: "\(item.id)-one", offset: 0, kind: .chat, author: "Fan", text: "What a finish!")]
    }
}
@MainActor private final class EmptyTimeline: HMStreamTimeline {
    var duration: TimeInterval { 0 }
    var density: [HMDensityBucket] { [] }
    var markers: [HMTimelineMarker] { [] }
    func events(in range: ClosedRange<TimeInterval>) -> [HMTimelineEvent] { [] }
}
