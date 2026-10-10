import SwiftUI
import Observation
import UIKit
import HotMicPlayer
import HotMicPlayerUI

/// Generic integration demo: fake host backend, mixed media, persistent host navigation.
struct PartnerDemoScreen: View {
    @State private var model = PartnerDemoModel()
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
                Text(customUI ? "Custom UI on hooks" : "Partner demo · Kit UI").font(.caption).lineLimit(1)
                if !notice.isEmpty { Text(notice).font(.caption).lineLimit(1).accessibilityIdentifier("partner-notice") }
                }
                if model.player.adState.isActive {
                    Button("Skip ad") { model.player.skipAd() }.frame(minHeight: 44).accessibilityIdentifier("partner-skip-ad")
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
        .onDisappear { model.player.teardown() }
    }
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

@MainActor @Observable private final class PartnerDemoModel {
    var player: HMPlayer
    private var connect = false
    private var started = false
    @ObservationIgnored private var adapters: [String: HMEngagementSocialAdapter] = [:]
    var error: String?
    init() { player = HMPlayer(interactions: CustomEngagementBackend()) }
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

/// Deliberately host-owned chrome using only core playback/layout/gesture APIs.
private struct PartnerCustomSurface: View {
    let player: HMPlayer
    let data: (HMMediaItem) -> any HMSocialDataSource
    let navHeight: CGFloat
    @State private var sheetHeight: CGFloat = 0
    @State private var fire = false
    var body: some View {
        GeometryReader { geometry in
            HMVerticalFeedView(player: player) { item, snapshot in
                GeometryReader { cell in
                    VStack {
                        Spacer()
                        if player.adState.isActive { EmptyView() } else if sheetHeight == 0 {
                            HMHitArea {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(data(item).content.title).font(.headline)
                                    Text("Host-designed controls").font(.caption)
                                    HStack {
                                        Button(fire ? "Fire, reacted" : "Fire") { react(item) }
                                        Button("Comments") { sheetHeight = 360 }
                                        if let url = item.url { ShareLink("Share", item: url) }
                                        Button("Fullscreen") { player.enterFullscreen() }
                                    }.frame(minHeight: 44)
                                }.padding().background(.black.opacity(0.65))
                            }
                        } else {
                            HMHitArea {
                                VStack {
                                    Button("Close comments") { sheetHeight = 0 }.frame(minHeight: 44)
                                    Text("Host comment sheet").font(.headline)
                                    ForEach(data(item).content.comments) { Text("\($0.author): \($0.text)") }
                                    Spacer()
                                }.padding().frame(height: sheetHeight).frame(maxWidth: .infinity).background(.regularMaterial)
                                .gesture(DragGesture().onChanged { sheetHeight = max(120, 360 - $0.translation.height) }
                                    .onEnded { if $0.translation.height > 160 { sheetHeight = 0 } })
                            }
                        }
                    }.padding(.bottom, navHeight + geometry.safeAreaInsets.bottom)
                }
            }
            .hmVideoLayout(HMVideoLayout(contentInsets: HMVideoInsets(bottom: navHeight + geometry.safeAreaInsets.bottom),
                squeezeTarget: sheetHeight > 0 ? CGRect(x: 0, y: 0, width: geometry.size.width, height: geometry.size.height - sheetHeight) : nil))
            .hmVideoGestures(isAdPlaying: player.adState.isActive, onTap: { player.togglePlayPause() },
                onDoubleTap: { _ in if let item = player.currentItem { react(item) } })
            .onChange(of: player.adState.isActive) { _, active in if active { sheetHeight = 0 } }
        }
    }
    private func react(_ item: HMMediaItem) {
        fire = true
        Task { try? await data(item).setReacted(true) }
    }
}
