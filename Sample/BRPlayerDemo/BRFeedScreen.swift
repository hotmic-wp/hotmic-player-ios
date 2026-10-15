import SwiftUI
import Observation
import HotMicPlayer
import HotMicPlayerUI

/// Home screen of the BR demo: the partner demo's ready-made social feed on BR clips.
/// Started as a copy of PartnerDemoScreen's kit path; BR behaviour grows here, never in the SDK.
struct BRFeedScreen: View {
    @StateObject private var owner = BRFeedOwner()
    private var model: BRFeedModel { owner.model }
    @State private var sheetOpen = false
    @State private var muteControl = false
    @State private var scrubbing = false
    @State private var previewOnce = false
    @State private var shareURL: URL?
    @State private var sharePresented = false
    @State private var notice = ""
    @Environment(\.scenePhase) private var scenePhase
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
        GeometryReader { geometry in
        ZStack {
            kit.hmExcludedHitAreas([CGRect(x: 0, y: 0, width: geometry.size.width, height: geometry.safeAreaInsets.top + 100)])
            VStack {
                if !sheetOpen {
                HStack {
                    Text("B/R demo").font(.headline).accessibilityIdentifier("br-demo-title")
                    Spacer()
                    Menu {
                        Button("Toggle captions") { model.player.captionsEnabled.toggle() }
                        Button("Refresh ranking") { model.refreshRanking() }
                        Toggle("Show mute control", isOn: $muteControl)
                        Toggle("Allow scrubbing", isOn: $scrubbing)
                        Toggle("Preview once per item", isOn: $previewOnce)
                        Button("Landscape item") { model.player.jump(toID: BRDemoContent.landscapeID) }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.system(size: 22)).frame(width: 44, height: 44)
                    }.accessibilityLabel("Demo options").accessibilityIdentifier("br-demo-options")
                }
                .padding(.horizontal, 16).background(.black.opacity(0.7))
                if !notice.isEmpty { Text(notice).font(.caption).lineLimit(1).accessibilityIdentifier("br-demo-notice") }
                }
                if let error = model.error { Text(error).foregroundStyle(.red) }
                Spacer()
            }
        }
        }
        .tint(.white)
        .ignoresSafeArea(.keyboard)
        .preferredColorScheme(.dark).foregroundStyle(.white)
        .sheet(isPresented: $sharePresented) { if let shareURL { HMShareSheet(items: [shareURL]) } }
        .task { await model.start() }
        .onAppear { model.player.isFeedVisible = true }
        .onChange(of: scenePhase) { _, phase in model.player.isFeedVisible = phase == .active }
    }
    private var kit: HMSocialPlayerView {
        HMSocialPlayerView(player: model.player, options: options, callbacks: callbacks, data: model.data)
    }
}

@MainActor private final class BRFeedOwner: ObservableObject {
    let model = BRFeedModel()
}

@MainActor @Observable private final class BRFeedModel {
    var player: HMPlayer
    private var started = false
    @ObservationIgnored private var adapters: [String: HMEngagementSocialAdapter] = [:]
    var error: String?
    init() { player = HMPlayer(interactions: BRDemoSource()) }
    deinit { MainActor.assumeIsolated { player.teardown() } }
    func refreshRanking() {
        guard let current = player.currentItem else { return }
        player.reconcile([current] + player.items.filter { $0.id != current.id }.reversed())
    }
    func data(_ item: HMMediaItem) -> any HMSocialDataSource {
        let engagement = player.engagement(for: item)
        if let adapter = adapters[item.id], adapter.engagement === engagement { return adapter }
        let adapter = HMEngagementSocialAdapter(engagement: engagement, metadata: BRDemoContent.metadata(for: item))
        adapters[item.id] = adapter; return adapter
    }
    func start() async {
        guard !started else { return }
        started = true
        player.replaceAll(BRDemoContent.items)
        await player.start()
        do {
            // Media-clock replay has no comment pages; loading one would switch replay off.
            for item in player.items where data(item).canLoadMore { try await data(item).loadMoreComments() }
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}
