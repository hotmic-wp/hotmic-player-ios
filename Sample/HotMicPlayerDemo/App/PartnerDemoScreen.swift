import SwiftUI
import Observation
import UIKit
import HotMicPlayer
import HotMicPlayerUI

/// Generic integration demo: fake host backend, mixed media, persistent host navigation.
struct PartnerDemoScreen: View {
    @State private var model = PartnerDemoModel()
    @State private var customUI = false
    @State private var muteControl = false
    @State private var scrubbing = false
    @State private var customSheet = false
    @State private var shareURL: URL?
    @State private var sharePresented = false
    @State private var notice = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType
    private var options: HMSocialOptions {
        var options = HMSocialOptions()
        options.hostNavigationHeight = 54; options.showsMute = muteControl; options.allowsScrubbing = scrubbing
        options.previewDuration = 3; options.previewRotationInterval = 5
        return options
    }
    private var callbacks: HMSocialCallbacks {
        var callbacks = HMSocialCallbacks()
        callbacks.hashtagTapped = { notice = "Hashtag: \($0)" }
        callbacks.share = { shareURL = $0.url; sharePresented = true }
        callbacks.commentPosted = { _, _ in notice = "Comment posted" }
        callbacks.sheetChanged = { _, opened in notice = opened ? "Comments opened" : "Comments closed" }
        return callbacks
    }
    var body: some View {
        GeometryReader { geometry in
        ZStack {
            if customUI {
                PartnerCustomSurface(player: model.player, data: model.data, navHeight: 54)
            } else {
                kit.hmExcludedHitAreas([CGRect(x: 0, y: 0, width: geometry.size.width, height: geometry.safeAreaInsets.top + 100)])
            }
            VStack {
                HStack {
                    Button("Close") { dismiss() }.frame(minHeight: 44)
                    Spacer()
                    Menu("Demo options") {
                        Toggle("Custom UI on hooks", isOn: $customUI)
                        Toggle("Show mute control", isOn: $muteControl)
                        Toggle("Allow scrubbing", isOn: $scrubbing)
                        Toggle("Replace sheet content", isOn: $customSheet)
                        Button("Landscape item") { model.player.next() }
                        Button("Ad placeholder") { model.player.jump(toID: "host-ad") }
                        Button("Vertical item") { model.player.jump(toID: "kit-vertical") }
                    }.accessibilityIdentifier("partner-options").frame(minHeight: 44)
                }
                .padding(.horizontal, 16).background(.black.opacity(0.7))
                Text(customUI ? "Custom UI on hooks" : "Partner demo · Kit UI").font(.caption)
                if !notice.isEmpty { Text(notice).font(.caption).accessibilityIdentifier("partner-notice") }
                if model.player.adState.isActive {
                    Button("Skip ad") { model.player.skipAd() }.accessibilityIdentifier("partner-skip-ad")
                }
                if let error = model.error { Text(error).foregroundStyle(.red) }
                Spacer()
                HStack {
                    Label("Home", systemImage: "house.fill")
                    Spacer(); Label("Following", systemImage: "person.2")
                    Spacer(); Label("Profile", systemImage: "person.crop.circle")
                }.font(.caption).padding(.horizontal, 20).frame(height: 54)
                    .background(.black).accessibilityIdentifier("partner-bottom-nav")
            }
        }
        }
        .preferredColorScheme(.dark).foregroundStyle(.white)
        .sheet(isPresented: $sharePresented) { if let shareURL { HMShareSheet(items: [shareURL]) } }
        .task { await model.start() }
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
        return view
    }
}

@MainActor @Observable private final class PartnerDemoModel {
    let player: HMPlayer
    private let source = CustomEngagementBackend()
    @ObservationIgnored private var adapters: [String: HMEngagementSocialAdapter] = [:]
    var error: String?
    init() { player = HMPlayer(configuration: HMPlayerConfiguration(), interactions: source) }
    func data(_ item: HMMediaItem) -> any HMSocialDataSource {
        if let adapter = adapters[item.id] { return adapter }
        let adapter = HMEngagementSocialAdapter(engagement: player.engagement(for: item), metadata: HMSocialContent(
            title: item.title ?? "The moment everyone is talking about",
            description: "Every play has a story. Join the conversation and share your view of this moment with the community. Watch again to catch every detail of the action.",
            hashtags: ["Highlights", "GameDay"], community: "Courtside community"))
        adapters[item.id] = adapter; return adapter
    }
    func start() async {
        guard player.items.isEmpty else { return }
        do {
            let vertical = try await socialVideoFixture(landscape: false, name: "kit-vertical", seconds: 12)
            let horizontal = try await socialVideoFixture(landscape: true, name: "kit-horizontal", seconds: 12)
            let captions = Bundle.main.url(forResource: "bench.en", withExtension: "vtt").map { ["en": $0] } ?? [:]
            player.adBreakProvider = DemoAdProvider(preRollURL: horizontal)
            player.replaceAll([
                HMMediaItem(id: "kit-vertical", url: vertical, title: "A moment to share", aspectRatio: 9.0 / 16, captionSources: captions),
                HMMediaItem(id: "kit-horizontal", url: horizontal, title: "The whole field, in view", aspectRatio: 16.0 / 9, captionSources: captions),
                HMMediaItem(id: "host-ad", url: vertical, title: "Back to the action", aspectRatio: 9.0 / 16)
            ])
            await player.start()
            for item in player.items { try await data(item).loadMoreComments() }
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
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
