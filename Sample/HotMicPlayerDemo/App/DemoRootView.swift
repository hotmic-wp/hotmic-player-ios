import SwiftUI
import HotMicPlayer

/// Partner demo navigation and public playback wiring.
struct DemoRootView: View {
    @State private var settings = DemoSettings()
    @State private var console = HMConsoleSink()
    @State private var muxBridge = DemoMuxBridge()
    @State private var controller: HMPlayer?
    @State private var showsPartner = false
    @State private var showsSocial = false
    @State private var showsHorizontal = false
    @State private var showsPlaylist = false
    @State private var bootstrapError: String?
    @State private var isFeedPresented = false
    @Environment(\.scenePhase) private var scenePhase
    private let options = DemoOptions()

    @ViewBuilder var body: some View {
        #if DEBUG
        if options.values["ads-lab"] == "1" { AdsLabScreen() }
        else if options.values["accessibility-lab"] == "1" { CaptionsAudioLabScreen() }
        else if options.values["reference-lab"] == "1" { ReferenceLabScreen() }
        else if options.values["horizontal-lab"] == "1" { RegressionHorizontalScreen() }
        else { selectedDemo }
        #else
        selectedDemo
        #endif
    }
    @ViewBuilder private var selectedDemo: some View {
        if options.values["partner-demo"] == "1" { PartnerDemoScreen() }
        else if options.values["social-layout"] == "1" { SocialLayoutScreen() }
        else if options.values["playlist-lab"] == "1" { PlaylistLabScreen(onBack: {}) }
        else { demoBody }
    }
    private var demoBody: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let controller {
                PlaylistView(controller: controller, settings: settings, onPlay: { open(controller, at: $0) }, console: console, muxBridge: muxBridge)
            } else if let bootstrapError { Text(bootstrapError).accessibilityIdentifier("demo-error") }
            else { ProgressView().tint(.white) }
        }
        .fullScreenCover(isPresented: $isFeedPresented) {
            if let controller {
                FeedScreen(controller: controller, settings: settings, console: console, muxBridge: muxBridge,
                    onBack: { controller.isFeedVisible = false; isFeedPresented = false })
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Partner demo") { showsPartner = true }.accessibilityIdentifier("partner-demo")
                Button("Social layout") { showsSocial = true }
                Button("Horizontal") { showsHorizontal = true }
                Button("Playlist") { showsPlaylist = true }.accessibilityIdentifier("playlist-lab")
            }.font(.caption).padding(12)
        }
        .fullScreenCover(isPresented: $showsPartner) { PartnerDemoScreen() }
        .fullScreenCover(isPresented: $showsSocial) { SocialLayoutScreen() }
        .fullScreenCover(isPresented: $showsHorizontal) { HorizontalLabScreen(onBack: { showsHorizontal = false }) }
        .fullScreenCover(isPresented: $showsPlaylist) { PlaylistLabScreen(onBack: { showsPlaylist = false }) }
        .tint(DemoTheme.accent)
        .preferredColorScheme(options.values["appearance"] == "light" ? .light : .dark)
        .task { await bootstrapIfNeeded() }
        .onChange(of: scenePhase) { _, phase in controller?.isFeedVisible = isFeedPresented && phase == .active }
    }
    private func open(_ controller: HMPlayer, at index: Int) {
        guard controller.items.indices.contains(index) else { return }
        controller.jump(toID: controller.items[index].id)
        controller.isFeedVisible = true
        isFeedPresented = true
    }
    private func bootstrapIfNeeded() async {
        guard controller == nil else { return }
        let hub = HMAnalyticsHub(); hub.add(console)
        hub.add(HMMuxAnalyticsSink(environment: HMMuxEnvironment(environmentKey: "demo-env-key",
            playerName: "HotMicVerticalFeed", viewerUserID: "demo-viewer-001", customDimensions: ["surface": "sample-app"]), bridge: muxBridge))
        do {
            var configuration = HMPlayerConfiguration.default
            var interactions: any HMInteractionSource = CustomEngagementBackend()
            var source: any HMPlaylistSource
            #if DEBUG
            let regression = options.values["regression-feed"] == "1" || options.values["probe"] == "1"
            if regression { configuration.startsMuted = true; source = try await RegressionSupport.source() }
            else { source = try await options.dataSource() }
            if regression || options.values["open-feed"] != nil { interactions = RegressionSupport.interactions() }
            if options.values["moderation-eviction"] == "1" {
                configuration.resolveAhead = 0; configuration.prefetch = .off; configuration.poolSize = 1; configuration.adaptive = false
            }
            #else
            source = try await options.dataSource()
            #endif
            let created = HMPlayer(configuration: configuration, interactions: interactions, analytics: hub)
            created.playlistSource = source; created.isFeedVisible = false
            settings.applyConfiguration = { [weak created] in created?.configuration = $0 }
            settings.showsHUD = false
            controller = created
            await created.start()
            #if DEBUG
            if regression { settings.showsOverlays = false; open(created, at: options.startIndex) }
            else if let index = options.values["open-feed"].flatMap(Int.init) { open(created, at: index) }
            #else
            if let index = options.values["open-feed"].flatMap(Int.init) { open(created, at: index) }
            #endif
        } catch { bootstrapError = error.localizedDescription }
    }
}
