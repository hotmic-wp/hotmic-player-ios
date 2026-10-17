import SwiftUI
import Observation
@_spi(Benchmark) import HotMicPlayer
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
    @State private var signInOpen = false
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
        options.showsCompanionChrome = true
        // Landscape fullscreen: nothing over the video but the player's corner exit; a tap plays and pauses.
        options.fullscreenControls = .hidden
        return options
    }
    private var callbacks: HMSocialCallbacks {
        var callbacks = HMSocialCallbacks()
        callbacks.hashtagTapped = { hashtag = BRHashtag(tag: $0) }
        callbacks.share = {
            model.player.setCompanionCovered(true, by: "share")
            shareURL = $0.url; sharePresented = true
        }
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
                        Menu("Side-car") {
                            Picker("Side-car timing (next replay)", selection: Binding(
                                get: { model.sideCarTiming }, set: { model.sideCarTiming = $0 }
                            )) {
                                ForEach(BRFeedModel.SideCarTiming.allCases) { timing in
                                    Text(timing.rawValue).tag(timing)
                                }
                            }
                            Button("Replay the side-car — next eligible clip") {
                                model.replaySideCar()
                                notice = "Side-car reset. Swipe to an eligible clip (2–9)."
                            }
                            Toggle("Simulate Picture in Picture", isOn: Binding(
                                get: { model.player.isPictureInPictureActive },
                                set: { model.player.isPictureInPictureActive = $0 }
                            ))
                            Toggle("Simulate AirPlay", isOn: Binding(
                                get: { model.simulatesAirPlay }, set: { model.simulatesAirPlay = $0 }
                            ))
                            Button("Show sign-in prompt") {
                                model.player.setCompanionCovered(true, by: "signIn")
                                signInOpen = true
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.system(size: 22)).frame(width: 44, height: 44)
                    }.accessibilityLabel("Demo options").accessibilityIdentifier("br-demo-options")
                }
                .padding(.horizontal, 16).background(.black.opacity(0.7))
                }
                if case .playing = model.player.adState {
                    Text("Ad · 0:15").font(.caption.bold()).padding(8)
                        .background(.black.opacity(0.75), in: Capsule())
                        .allowsHitTesting(false).accessibilityIdentifier("br-preroll-label")
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
        .hmTheme(BRTheme.theme)
        .ignoresSafeArea(.keyboard)
        .preferredColorScheme(.dark).foregroundStyle(.white)
        .sheet(isPresented: $sharePresented, onDismiss: {
            model.player.setCompanionCovered(false, by: "share")
        }) { if let shareURL { HMShareSheet(items: [shareURL]) } }
        .sheet(isPresented: $signInOpen, onDismiss: {
            model.player.setCompanionCovered(false, by: "signIn")
        }) {
            VStack(spacing: 20) {
                Text("Sign-in prompt (stand-in)").font(.title2.bold())
                Text("Your app owns sign-in. This demo creates no account and collects no information. The side-car pauses while this sheet covers it.")
                    .multilineTextAlignment(.center)
                Button("Close sign-in prompt") { signInOpen = false }.buttonStyle(.borderedProminent)
            }
            .padding(24).presentationDetents([.large])
        }
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
        let kit = HMSocialPlayerView(player: model.player, options: options, callbacks: callbacks, data: model.data)
            .actionRail { item, context in BRActionRail(item: item, context: context) }
            .metadata { _, context in BRMetadata(context: context) }
        // Do not reserve an empty banner slot on clips without a banner.
        guard let current = model.player.currentItem,
              BRDemoContent.catalog.clip(forItemID: current.id)?.banner != nil else { return kit }
        return kit.sidecar(size: CGSize(width: 240, height: 60)) { item in
                if let banner = BRDemoContent.catalog.clip(forItemID: item.id)?.banner {
                    AsyncImage(url: banner) { image in image.resizable().scaledToFit() }
                        placeholder: { Color.clear }
                        .accessibilityLabel("Sponsor banner (stand-in)")
                        .accessibilityIdentifier("br-sponsor-banner")
                        .allowsHitTesting(false)
                }
            }
    }
}

@MainActor private final class BRFeedOwner: ObservableObject {
    let model = BRFeedModel()
}

/// Internal so the Home entries (`BRDemoEntries.swift`) can extend it.
@MainActor @Observable final class BRFeedModel {
    enum SideCarTiming: String, CaseIterable, Identifiable {
        case standard = "10s / 5s countdown"
        case extended = "20s / 3s countdown"
        var id: Self { self }
        var trigger: HMCompanionTrigger {
            switch self {
            case .standard: HMCompanionTrigger(watchedTime: 10, countdown: 5, scope: .session)
            case .extended: HMCompanionTrigger(watchedTime: 20, countdown: 3, scope: .session)
            }
        }
    }
    var player: HMPlayer
    @ObservationIgnored private let adProvider = BRDemoAdProvider()
    /// Trigger settings are sampled at the next companion decision. Replay, then swipe to apply.
    var sideCarTiming: SideCarTiming = .standard {
        didSet { player.configuration.companionTrigger = sideCarTiming.trigger }
    }
    var simulatesAirPlay = false {
        didSet { player.externalPlaybackOverride = simulatesAirPlay ? true : nil }
    }
    private var started = false
    @ObservationIgnored private var adapters: [String: HMEngagementSocialAdapter] = [:]
    var error: String?
    init() {
        // Failed clips stay current so the retry control in the squeezed frame can be exercised.
        var configuration = HMPlayerConfiguration.default
        configuration.failedItemPolicy = .stay
        player = HMPlayer(configuration: configuration, interactions: BRDemoSource())
        player.adBreakProvider = adProvider
    }
    func replaySideCar() {
        player.dismissCompanion()
        adProvider.resetSideCar()
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
