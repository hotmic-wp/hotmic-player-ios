import SwiftUI
import Observation
import UIKit
import HotMicPlayer
import HotMicPlayerUI

/// Generic integration demo: fake host backend, mixed media, persistent host navigation.
struct PartnerDemoScreen: View {
    @StateObject private var owner = PartnerDemoOwner()
    private var model: PartnerDemoModel { owner.model }
    @State private var customUI = false
    @State private var useConnect = false
    @State private var selectedTab = 0
    @State private var sheetOpen = false
    @State private var muteControl = false
    @State private var scrubbing = false
    @State private var customSheet = false
    @State private var customSlots = false
    @State private var previewOnce = false
    @State private var shareURL: URL?
    @State private var sharePresented = false
    @State private var notice = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType
    private var options: HMSocialOptions {
        var options = HMSocialOptions()
        options.hostNavigationHeight = 0; options.showsMute = muteControl; options.allowsScrubbing = scrubbing
        options.previewDuration = 3; options.previewRotationInterval = previewOnce ? nil : 5
        return options
    }
    private var callbacks: HMSocialCallbacks {
        var callbacks = HMSocialCallbacks()
        callbacks.hashtagTapped = { notice = "Hashtag: \($0)" }
        callbacks.share = { shareURL = $0.url; sharePresented = true }
        callbacks.commentPosted = { _, _ in notice = "Comment posted" }
        callbacks.sheetChanged = { _, opened in sheetOpen = opened; notice = opened ? "Comments opened" : "Comments closed" }
        return callbacks
    }
    var body: some View {
        TabView(selection: $selectedTab) {
        GeometryReader { geometry in
        ZStack {
            if customUI {
                PartnerCustomSurface(player: model.player, data: model.data, navHeight: 0)
            } else {
                kit.hmExcludedHitAreas([CGRect(x: 0, y: 0, width: geometry.size.width, height: geometry.safeAreaInsets.top + 100)])
            }
            VStack {
                if !sheetOpen {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 20)).frame(width: 44, height: 44) }.accessibilityLabel("Close")
                    Spacer()
                    Menu {
                        Toggle("Custom UI on hooks", isOn: $customUI)
                        Toggle("Fake Connect source", isOn: $useConnect)
                        Button("Toggle captions") { model.player.captionsEnabled.toggle() }
                        Button("Refresh ranking") { model.refreshRanking() }
                        Button("URL pre-roll") { model.player.jump(toID: "url-ad") }
                        Toggle("Show mute control", isOn: $muteControl)
                        Toggle("Allow scrubbing", isOn: $scrubbing)
                        Toggle("Replace sheet content", isOn: $customSheet)
                        Toggle("Replace rail and metadata", isOn: $customSlots)
                        Toggle("Preview once per item", isOn: $previewOnce)
                        Button("Landscape item") { model.player.jump(toID: "kit-horizontal") }
                        Button("HLS item") { model.player.jump(toID: "hls") }
                        Button("Host-played break") { model.player.jump(toID: "host-ad") }
                        Button("Vertical item") { model.player.jump(toID: "kit-vertical") }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.system(size: 22)).frame(width: 44, height: 44)
                    }.accessibilityLabel("Demo options").accessibilityIdentifier("partner-options")
                }
                .padding(.horizontal, 16).background(.black.opacity(0.7))
                Text(customUI ? "Partner demo · Custom UI" : "Partner demo · Kit UI").font(.caption).lineLimit(1)
                if !notice.isEmpty { Text(notice).font(.caption).lineLimit(1).accessibilityIdentifier("partner-notice") }
                }
                if model.player.adState.isActive {
                    Button("Skip ad") { model.player.skipAd() }.frame(minHeight: 44).accessibilityIdentifier("partner-skip-ad")
                        .disabled(model.player.adProgress.elapsed < 3 || !adPlaying) // Fake host's skip policy.
                }
                if let error = model.error { Text(error).foregroundStyle(.red) }
                Spacer()
            }
        }
        }
        .id(ObjectIdentifier(model.player))
        .tabItem { Label("Feed", systemImage: "play.rectangle.fill") }.tag(0)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Integration walkthrough").font(.title)
                Text("Choose ready-made or custom overlay in Demo options. Both share playback and fake services.")
                ForEach(["Swipe portrait, landscape and HLS; refresh ranking.",
                    "Tap to pause, double tap to add Fire; rail toggles it.",
                    "Open comments, load older rows, type and post with the software keyboard.",
                    "Toggle captions and mute. Enter fullscreen on landscape and return.",
                    "Run URL pre-roll and host-played break; skip, swipe away and revisit.",
                    "Switch fake host / Connect source; simulated Connect capabilities exceed current backend availability.",
                    "Try replacement rail, metadata, sheet and safe sidecar.",
                    "Check largest text, Reduce Motion, background / foreground; use the audio lab for simulated interruptions."], id: \.self) { Text($0) }
            }.padding()
        }.tabItem { Label("Guide", systemImage: "checklist") }.tag(1)
        }
        .tint(.white)
        .ignoresSafeArea(.keyboard)
        .preferredColorScheme(.dark).foregroundStyle(.white)
        .sheet(isPresented: $sharePresented) { if let shareURL { HMShareSheet(items: [shareURL]) } }
        .task { await model.start() }
        .task(id: useConnect) { await model.selectSource(connect: useConnect) }
        .onChange(of: selectedTab) { _, tab in model.player.isFeedVisible = tab == 0 }
        #if DEBUG
        .task(id: "\(reduceMotion)|\(dynamicType)") {
            guard BenchmarkOptions().values["partner-trace"] == "1" else { return }
            await model.record(reduceMotion: reduceMotion, dynamicType: String(describing: dynamicType))
        }
        #endif
        .onAppear { model.player.isFeedVisible = selectedTab == 0 }
        .onDisappear { model.player.isFeedVisible = false }
    }
    private var adPlaying: Bool { if case .playing = model.player.adState { return true }; return false }
    private var kit: HMSocialPlayerView {
        var view = HMSocialPlayerView(player: model.player, options: options, callbacks: callbacks, data: model.data)
            .sidecar(size: CGSize(width: 120, height: 54)) { _ in
                Button("Sidecar ad slot") { notice = "Sidecar tapped" }
                    .font(.caption).frame(maxWidth: .infinity, maxHeight: .infinity).background(.indigo, in: RoundedRectangle(cornerRadius: 10))
            }
        if customSheet {
            view = view.commentSheet { item in
                VStack { Text("Host sheet content"); HMCommentSheet(data: model.data(item)) }
            }
        }
        if customSlots {
            view = view.actionRail { _, context in
                HMActionRail(content: context.content, canFire: context.canFire, fireEvent: context.fireEvent,
                    onFire: context.fire, onComment: context.openComments, onShare: context.share,
                    onFireFrame: context.fireFrameChanged)
                    .padding(6).background(.indigo.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
            }.metadata { _, context in
                HMMetadataView(content: context.content, onExpand: context.expand, onHashtag: context.hashtagTapped)
                    .padding(6).background(.indigo.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        return view
    }
}

@MainActor private final class PartnerDemoOwner: ObservableObject {
    let model = PartnerDemoModel()
}

@MainActor @Observable private final class PartnerDemoModel {
    var player: HMPlayer
    private var connect = false
    private var started = false
    @ObservationIgnored private var adapters: [String: HMEngagementSocialAdapter] = [:]
    var error: String?
    init() { player = HMPlayer(interactions: CustomEngagementBackend()) }
    deinit { MainActor.assumeIsolated { player.teardown() } }
    func selectSource(connect: Bool) async {
        guard connect != self.connect else { return }
        self.connect = connect; error = nil
        player.teardown(); adapters.removeAll(); started = false
        player = HMPlayer(interactions: connect ? DemoConnectInteractionSource() : CustomEngagementBackend())
        await start()
    }
    func refreshRanking() {
        guard let current = player.currentItem else { return }
        player.reconcile([current] + player.items.filter { $0.id != current.id }.reversed())
    }
    func data(_ item: HMMediaItem) -> any HMSocialDataSource {
        let engagement = player.engagement(for: item)
        if let adapter = adapters[item.id], adapter.engagement === engagement { return adapter }
        let adapter = HMEngagementSocialAdapter(engagement: engagement, metadata: HMSocialContent(
            title: item.title ?? "The moment everyone is talking about",
            description: "Every play has a story. Join the conversation and share your view of this moment with the community. Watch again to catch every detail of the action.",
            hashtags: ["Highlights", "GameDay"], community: "Courtside community"))
        adapters[item.id] = adapter; return adapter
    }
    func start() async {
        guard !started else { return }
        started = true
        let activePlayer = player
        do {
            let vertical = try await socialVideoFixture(landscape: false, name: "kit-vertical", seconds: 12)
            let horizontal = try await socialVideoFixture(landscape: true, name: "kit-horizontal", seconds: 12)
            let captions = Bundle.main.url(forResource: "bench.en", withExtension: "vtt").map { ["en": $0] } ?? [:]
            guard activePlayer === player else { return }
            let hlsURL = BenchmarkOptions().values["partner-hls-url"].flatMap(URL.init(string:))
                ?? URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!
            player.adBreakProvider = DemoAdProvider(preRollURL: horizontal)
            player.replaceAll([
                HMMediaItem(id: "kit-vertical", url: vertical, title: "A moment to share", aspectRatio: 9.0 / 16, captionSources: captions),
                HMMediaItem(id: "kit-horizontal", url: horizontal, title: "The whole field, in view", aspectRatio: 16.0 / 9, captionSources: captions),
                HMMediaItem(id: "hls", url: hlsURL, format: .hls, title: "HLS match replay", aspectRatio: 16.0 / 9),
                HMMediaItem(id: "url-ad", url: vertical, title: "After URL pre-roll", aspectRatio: 9.0 / 16, captionSources: captions),
                HMMediaItem(id: "host-ad", url: vertical, title: "Back to the action", aspectRatio: 9.0 / 16)
            ])
            await player.start()
            for item in activePlayer.items {
                guard activePlayer === player else { return }
                try await data(item).loadMoreComments()
            }
        } catch is CancellationError { }
        catch { if activePlayer === player { self.error = error.localizedDescription } }
    }
    #if DEBUG
    /// Opt-in local diagnostics use public UIKit accessibility and player APIs only.
    func record(reduceMotion: Bool, dynamicType: String) async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let output = documents.appendingPathComponent("partner-state.json")
        let command = documents.appendingPathComponent("partner-command.txt")
        var lastCommand = ""
        while !Task.isCancelled {
            func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
            let elements = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).flatMap(views).flatMap { $0.accessibilityElements ?? [] }
                .compactMap { $0 as? UIAccessibilityElement }
                .filter { $0.accessibilityIdentifier?.hasPrefix("hm-") == true }
            if let text = try? String(contentsOf: command, encoding: .utf8), text != lastCommand {
                lastCommand = text
                if text.hasPrefix("fire|") {
                    if let action = elements.flatMap({ $0.accessibilityCustomActions ?? [] }).first(where: { $0.name == "Fire" }) {
                        _ = action.actionHandler?(action)
                    }
                }
            }
            let value: [String: Any] = ["item": player.currentItem?.id ?? "", "playhead": player.snapshot.currentTime,
                "state": player.snapshot.state.rawValue, "muted": player.isMuted, "fullscreen": player.isFullscreen,
                "adActive": player.adState.isActive, "reduceMotion": reduceMotion,
                "systemReduceMotion": UIAccessibility.isReduceMotionEnabled, "dynamicType": dynamicType,
                "elements": elements.map { ["id": $0.accessibilityIdentifier ?? "", "label": $0.accessibilityLabel ?? "",
                    "value": $0.accessibilityValue ?? "", "frame": NSCoder.string(for: $0.accessibilityFrame),
                    "actions": ($0.accessibilityCustomActions ?? []).map(\.name)] }]
            if let data = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys) { try? data.write(to: output, options: .atomic) }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        }
    }
    #endif

}

/// Deliberately host-owned chrome using only public playback/layout/gesture hooks.
private struct PartnerCustomSurface: View {
    let player: HMPlayer
    let data: (HMMediaItem) -> any HMSocialDataSource
    let navHeight: CGFloat
    @State private var sheetHeight: CGFloat = 0
    @State private var keyboard: CGFloat = 0
    var body: some View {
        GeometryReader { geometry in
            let safe = geometry.safeAreaInsets
            let fullHeight = geometry.size.height + safe.top + safe.bottom
            HMVerticalFeedView(player: player) { item, _ in
                PartnerCustomChrome(player: player, item: item, data: data(item), sheetHeight: $sheetHeight, keyboard: keyboard).id(item.id)
            }
            .hmVideoLayout(HMVideoLayout(contentInsets: HMVideoInsets(bottom: navHeight + geometry.safeAreaInsets.bottom),
                squeezeTarget: sheetHeight > 0 ? CGRect(x: 0, y: safe.top, width: geometry.size.width,
                    height: max(0, fullHeight - safe.top - safe.bottom - navHeight - sheetHeight - keyboard)) : nil))
            .hmVideoGestures(isAdPlaying: player.adState.isActive, onTap: { player.togglePlayPause() },
                onDoubleTap: { _ in
                    if let item = player.currentItem { Task { try? await data(item).setReacted(true) } }
                })
            .onChange(of: player.adState.isActive) { _, active in if active { sheetHeight = 0 } }
            .onChange(of: player.currentItem?.id) { _, _ in sheetHeight = 0 }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
                keyboard = max(0, geometry.frame(in: .global).maxY - end.minY - navHeight)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboard = 0 }
        }
    }
}

private struct PartnerCustomChrome: View {
    let player: HMPlayer
    let item: HMMediaItem
    let data: any HMSocialDataSource
    @Binding var sheetHeight: CGFloat
    let keyboard: CGFloat
    @State private var replayOwner = UUID()
    @State private var draft = ""
    @State private var error: String?
    @Environment(\.hmFeedSafeArea) private var safe
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
                if !player.adState.isActive && sheetHeight == 0 {
                    HMHitArea {
                        VStack(spacing: 16) {
                            Button {
                                Task { try? await data.setReacted(!data.content.isReacted) }
                            } label: {
                                PartnerHostAction(symbol: "flame.fill", title: "Fire",
                                    detail: data.content.fireCount.map { HMCountFormatter().string(from: $0) })
                                    .foregroundStyle(data.content.isReacted ? .orange : .white)
                            }.disabled(!data.canFire).accessibilityLabel("Fire")
                                .accessibilityValue(data.content.isReacted ? "Reacted" : "Not reacted")
                            Button { sheetHeight = 360 } label: {
                                PartnerHostAction(symbol: "bubble.right.fill", title: "Comments",
                                    detail: data.content.commentCount.map { HMCountFormatter().string(from: $0) })
                            }.accessibilityLabel("Comments")
                            if let url = item.url {
                                ShareLink(item: url) { PartnerHostAction(symbol: "arrowshape.turn.up.right.fill", title: "Share") }
                                    .accessibilityLabel("Share")
                            }
                        }.padding(10).background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 24))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 16).padding(.bottom, safe.bottom + 190)
                    HMHitArea {
                        VStack(alignment: .leading, spacing: 10) {
                            if let community = data.content.community {
                                Text(community.uppercased()).font(.caption2.bold()).tracking(1)
                                    .padding(.horizontal, 10).padding(.vertical, 6).background(.indigo, in: Capsule())
                            }
                            Text(data.content.title).font(.title2.bold()).lineLimit(textSize.isAccessibilitySize ? 1 : 2)
                            if !textSize.isAccessibilitySize {
                                Text(data.content.description).font(.subheadline).lineLimit(2).foregroundStyle(.white.opacity(0.8))
                                Text(data.content.hashtags.map { "#" + $0 }.joined(separator: "  ")).font(.caption.bold())
                            }
                            HStack(spacing: 8) {
                                control(player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", label: player.isMuted ? "Unmute" : "Mute") { player.toggleMute() }
                                if !player.availableCaptionLanguages.isEmpty {
                                    control("captions.bubble", label: "Closed captions") { player.captionsEnabled.toggle() }
                                }
                                control("arrow.up.left.and.arrow.down.right", label: player.isFullscreen ? "Exit fullscreen" : "Fullscreen") {
                                    if player.isFullscreen { player.exitFullscreen() } else { player.enterFullscreen() }
                                }
                            }
                        }.frame(maxWidth: max(0, geometry.size.width - 116), alignment: .leading)
                    }.padding(16).padding(.bottom, safe.bottom)
                }
                if sheetHeight > 0 && player.currentItem?.id == item.id && !player.adState.isActive {
                    HMHitArea {
                        VStack(spacing: 12) {
                            Capsule().fill(.secondary).frame(width: 40, height: 5)
                                .frame(maxWidth: .infinity).frame(height: 24).contentShape(Rectangle())
                                .gesture(DragGesture().onChanged { sheetHeight = max(120, 360 - $0.translation.height) }
                                    .onEnded { if $0.translation.height > 160 { sheetHeight = 0 } })
                            HStack { Text("Comments").font(.headline); Spacer(); Button("Close comments") { sheetHeight = 0 } }
                                .frame(minHeight: 44)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 14) {
                                    if data.canLoadMore { Button("Load older comments") { Task { try? await data.loadMoreComments() } } }
                                    ForEach(data.content.comments) { Text("\($0.author): \($0.text)") }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            HStack {
                                TextField("Add a comment", text: $draft).textFieldStyle(.roundedBorder).accessibilityIdentifier("partner-custom-input")
                                Button("Post") {
                                    let text = draft
                                    Task {
                                        do { try await data.postComment(text); if draft == text { draft = "" }; error = nil }
                                        catch { self.error = error.localizedDescription }
                                    }
                                }.disabled(draft.isEmpty || !data.canPost)
                            }.frame(minHeight: 44)
                            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                        }.padding().frame(height: sheetHeight).frame(maxWidth: .infinity)
                            .background(.black, in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
                    }.padding(.bottom, safe.bottom + keyboard)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).foregroundStyle(.white)
        }
        .task(id: player.currentItem?.id == item.id && player.isFeedVisible && !player.isFullscreen) { (data as? HMEngagementSocialAdapter)?.setReplayActive(player.currentItem?.id == item.id && player.isFeedVisible && !player.isFullscreen, for: replayOwner) }
        .onDisappear { (data as? HMEngagementSocialAdapter)?.setReplayActive(false, for: replayOwner) }
    }
    private func control(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44)
                .background(.white.opacity(0.12), in: Circle())
        }.accessibilityLabel(label)
    }
}

/// A host style shared conceptually with the core-only CustomOverlay starter.
private struct PartnerHostAction: View {
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
