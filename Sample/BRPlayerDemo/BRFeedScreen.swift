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
    @State private var homeOpen = false
    @State private var hashtag: BRHashtag?
    @State private var clipFailure = BRClipFailureHook()
    @Environment(\.scenePhase) private var scenePhase
    /// A host stand-in screen covers the feed; playback pauses until it closes.
    private var covered: Bool { homeOpen || hashtag != nil }
    private var options: HMSocialOptions {
        var options = HMSocialOptions()
        options.hostNavigationHeight = BRNavBar.height; options.showsMute = muteControl; options.allowsScrubbing = scrubbing
        options.previewDuration = 3; options.previewRotationInterval = previewOnce ? nil : 5
        // The two asks beyond the documents: recent comments on the video, and the live audience under the title.
        options.commentSelection = .recent(limit: 2)
        options.audienceBadgePlacement = .belowTitle
        // Squeezeback per BR's spec: three fixed sheet states, no paging while open, tap-to-minimise, retry in place.
        options.sheetMode = .snapped(squeezeFraction: 1.0 / 3)
        options.allowsPagingWhileSheetOpen = false
        options.closesSheetOnVideoTap = true
        options.showsPlaybackStatus = true
        return options
    }
    private var callbacks: HMSocialCallbacks {
        var callbacks = HMSocialCallbacks()
        callbacks.hashtagTapped = { hashtag = BRHashtag(tag: $0) }
        callbacks.share = { shareURL = $0.url; sharePresented = true }
        callbacks.commentPosted = { _, _ in notice = "Comment posted" }
        callbacks.sheetChanged = { _, opened in sheetOpen = opened }
        return callbacks
    }
    var body: some View {
        GeometryReader { geometry in
        ZStack {
            kit.hmExcludedHitAreas(hostChrome(geometry))
            VStack(spacing: 0) {
                if !sheetOpen {
                HStack {
                    Text("B/R demo").font(.headline).accessibilityIdentifier("br-demo-title")
                    Spacer()
                    Menu {
                        Button("Home") { homeOpen = true }
                        Button("Toggle captions") { model.player.captionsEnabled.toggle() }
                        Button("Refresh ranking") { model.refreshRanking() }
                        Toggle("Show mute control", isOn: $muteControl)
                        Toggle("Allow scrubbing", isOn: $scrubbing)
                        Toggle("Preview once per item", isOn: $previewOnce)
                        Button("Landscape item") { model.player.jump(toID: BRDemoContent.landscapeID) }
                        Button("Fail this clip") { clipFailure.fail(model.player) }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.system(size: 22)).frame(width: 44, height: 44)
                    }.accessibilityLabel("Demo options").accessibilityIdentifier("br-demo-options")
                }
                .padding(.horizontal, 16).background(.black.opacity(0.7))
                }
                if !notice.isEmpty {
                    // A short-lived toast, never a standing status line.
                    Text(notice).font(.caption).lineLimit(1).padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.black.opacity(0.75), in: Capsule()).padding(.top, 8)
                        .transition(.opacity).accessibilityIdentifier("br-demo-notice")
                }
                if let error = model.error { Text(error).foregroundStyle(.red) }
                Spacer()
                if !model.player.isFullscreen { BRNavBar(selected: .watch, onSelect: selectTab) }
            }
        }
        }
        .tint(.white)
        .ignoresSafeArea(.keyboard)
        .preferredColorScheme(.dark).foregroundStyle(.white)
        .sheet(isPresented: $sharePresented) { if let shareURL { HMShareSheet(items: [shareURL]) } }
        .fullScreenCover(isPresented: $homeOpen) {
            BRHomeScreen(onOpen: { entry in clipFailure.forget(); model.open(entry); homeOpen = false },
                         onClose: { homeOpen = false })
        }
        .fullScreenCover(item: $hashtag) { tag in BRHashtagScreen(hashtag: tag) { hashtag = nil } }
        .task(id: notice) {
            guard !notice.isEmpty else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            withAnimation { notice = "" }
        }
        .task { await model.start() }
        .onAppear { model.player.isFeedVisible = true }
        .onChange(of: scenePhase) { _, phase in model.player.isFeedVisible = phase == .active && !covered }
        .onChange(of: covered) { _, covered in model.player.isFeedVisible = !covered && scenePhase == .active }
        .onChange(of: model.player.snapshot.state) { _, _ in clipFailure.observe(model.player) }
        .onChange(of: model.player.currentItem?.id) { _, _ in clipFailure.observe(model.player) }
    }
    /// The demo header and the nav bar stand-in, in surface coordinates, kept clear of the video's taps.
    private func hostChrome(_ geometry: GeometryProxy) -> [CGRect] {
        let header = CGRect(x: 0, y: 0, width: geometry.size.width, height: geometry.safeAreaInsets.top + 100)
        guard !model.player.isFullscreen else { return [header] }
        let navTop = geometry.safeAreaInsets.top + geometry.size.height - BRNavBar.height
        return [header, CGRect(x: 0, y: navTop, width: geometry.size.width, height: BRNavBar.height + geometry.safeAreaInsets.bottom)]
    }
    private func selectTab(_ tab: BRNavBar.Tab) {
        switch tab {
        case .home: homeOpen = true
        case .watch: break
        case .scores, .search, .inbox: notice = "\(tab.rawValue): your app's tab (stand-in)"
        }
    }
    private var kit: HMSocialPlayerView {
        HMSocialPlayerView(player: model.player, options: options, callbacks: callbacks, data: model.data)
    }
}

@MainActor private final class BRFeedOwner: ObservableObject {
    let model = BRFeedModel()
}

/// Internal so the Home entries (`BRDemoEntries.swift`) can extend it.
@MainActor @Observable final class BRFeedModel {
    var player: HMPlayer
    private var started = false
    @ObservationIgnored private var adapters: [String: HMEngagementSocialAdapter] = [:]
    var error: String?
    init() {
        // Failed clips stay current so the retry control in the squeezed frame can be exercised.
        var configuration = HMPlayerConfiguration.default
        configuration.failedItemPolicy = .stay
        player = HMPlayer(configuration: configuration, interactions: BRDemoSource())
        // Throwaway for the companion device proof; the demo wiring ticket installs this properly.
        player.adBreakProvider = BRDemoAdProvider()
    }
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
