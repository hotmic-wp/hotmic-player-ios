import SwiftUI
@_spi(Benchmark) import HotMicPlayer

/// Hosts the two screens and owns everything long-lived: the feed controller,
/// the analytics sinks and the runtime settings.
struct DemoRootView: View {

    @State private var settings = DemoSettings()
    @State private var console = HMConsoleSink()
    @State private var muxBridge = HMLoggingMuxBridge()
    @State private var controller: HMPlayer?

    private let benchmark = BenchmarkOptions()
    @State private var showsSocial = false
    @State private var showsAds = false
    @State private var showsCaptions = false
    @State private var showsBenchmark = false
    @State private var showsLab = BenchmarkOptions().values["playlist-lab"] == "1"
    @State private var fileSink: HMJSONLFileSink?
    @State private var bootstrapError: String?
    @State private var isFeedPresented = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if benchmark.values["accessibility-lab"] == "1" {
            CaptionsAudioLabScreen()
        } else if benchmark.values["ads-lab"] == "1" {
            AdsLabScreen()
        } else if benchmark.values["social-layout"] == "1" {
            SocialLayoutScreen()
        } else if benchmark.values["horizontal-lab"] == "1" {
            HorizontalLabScreen()
        } else if benchmark.values["reference-lab"] == "1" {
            ReferenceLabScreen()
        } else if let url = benchmark.values["grid-url"] {
            BenchmarkScreen(initialURL: url, autoStart: true)
        } else {
            demoBody
        }
    }

    private var demoBody: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let controller {
                PlaylistView(
                    controller: controller,
                    settings: settings,
                    onPlay: { open(controller, at: $0) },
                    console: console,
                    muxBridge: muxBridge
                )
            } else {
                if let bootstrapError { Text(bootstrapError).accessibilityIdentifier("benchmark-error") }
                else { ProgressView().tint(.white) }
            }
        }
        // Deliberately a cover rather than a navigation push: the interactive
        // pop gesture fights the horizontal scrub gesture, and a full-bleed feed
        // has no use for a navigation bar.
        .fullScreenCover(isPresented: $isFeedPresented) {
            if let controller {
                FeedScreen(
                    controller: controller,
                    settings: settings,
                    console: console,
                    muxBridge: muxBridge,
                    onBack: { close(controller) },
                    fileSink: fileSink,
                    isBenchmark: benchmark.enabled
                )
            }
        }
        .overlay(alignment: .bottom) {
            HStack {
            Button("Captions + audio") { showsCaptions = true }
            Button("Ads lab") { showsAds = true }
            Button("Social layout") { showsSocial = true }
            Button("Playlist lab") { showsLab = true }.accessibilityIdentifier("playlist-lab")
            Button("Benchmark mode") {
                controller?.teardown()
                controller = nil
                fileSink = nil
                showsBenchmark = true
            }
                .accessibilityIdentifier("benchmark-mode").padding(12)
            }
        }
        .fullScreenCover(isPresented: $showsCaptions) { CaptionsAudioLabScreen() }
        .fullScreenCover(isPresented: $showsAds) { AdsLabScreen() }
        .fullScreenCover(isPresented: $showsSocial) { SocialLayoutScreen() }
        .fullScreenCover(isPresented: $showsLab) { PlaylistLabScreen { showsLab = false } }
        .fullScreenCover(isPresented: $showsBenchmark, onDismiss: {
            Task { await bootstrapIfNeeded() }
        }) { BenchmarkScreen() }
        .tint(DemoTheme.accent)
        // `--hm-appearance light` previews the engagement cards in light mode.
        .preferredColorScheme(benchmark.values["appearance"] == "light" ? .light : .dark)
        .task { await bootstrapIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            // Only the feed screen plays. Backgrounding while browsing the
            // playlist must not start anything.
            controller?.isFeedVisible = isFeedPresented && phase == .active
        }
    }

    // MARK: - Navigation

    private func open(_ controller: HMPlayer, at index: Int) {
        let requestedAt = ProcessInfo.processInfo.systemUptime
        Task {
            await controller.requestPlay(at: index, requestedAt: requestedAt)
            isFeedPresented = true
        }
    }

    private func close(_ controller: HMPlayer) {
        controller.isFeedVisible = false
        isFeedPresented = false
    }

    // MARK: - Wiring

    private func bootstrapIfNeeded() async {
        guard controller == nil, !showsBenchmark, !showsLab else { return }

        let hub = HMAnalyticsHub()
        hub.add(console)
        // MOCK — a real integration passes the production env key and a bridge
        // backed by MUXSDKStats. See Integrations/Mux/.
        hub.add(
            HMMuxAnalyticsSink(
                environment: HMMuxEnvironment(
                    environmentKey: "demo-env-key",
                    playerName: "HotMicVerticalFeed",
                    viewerUserID: "demo-viewer-001",
                    customDimensions: ["surface": "sample-app"]
                ),
                bridge: muxBridge
            )
        )

        do {
        if benchmark.values["reset-cache"] == "1" {
            let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("HotMicPlayer-v1")
            try? FileManager.default.removeItem(at: cache)
        }
        let configuration = try benchmark.configuration()
        let source = try await benchmark.dataSource()
        guard !showsBenchmark else { return }
        if benchmark.enabled {
            let safeID = benchmark.runID.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }.map(String.init).joined()
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("BenchRuns/\(safeID).jsonl")
            let sink = try HMJSONLFileSink(fileURL: url, runID: benchmark.runID, configuration: configuration,
                format: benchmark.values["format"] ?? "bundled", network: benchmark.values["network"] ?? "unspecified",
                script: benchmark.script, buildSHA: benchmark.values["build-sha"] ?? (Bundle.main.object(forInfoDictionaryKey: "HMBuildSHA") as? String ?? "unknown"))
            fileSink = sink; hub.add(sink)
        }
        let created = HMPlayer(
            configuration: configuration,
            // MOCK — every engagement action, accepted after a simulated round trip.
            interactions: HMMockInteractionSource(),
            analytics: hub
        )
        // Load playlist metadata while browsing, before the measured play tap.
        created.playlistSource = source
        created.isFeedVisible = false
        settings.applyConfiguration = { [weak created] configuration in
            created?.configuration = configuration
        }
        if !benchmark.enabled { settings.rebuildConfiguration() }
        #if DEBUG
        if benchmark.values["moderation-eviction"] == "1" {
            var narrow = created.configuration
            narrow.resolveAhead = 0; narrow.prefetch = .off; narrow.poolSize = 1; narrow.adaptive = false
            created.configuration = narrow
        }
        #endif
        if benchmark.values["hud"] == "0" { settings.showsHUD = false }
        else { settings.showsOverlays = false; settings.showsHUD = false }
        controller = created
        await created.start()
        if benchmark.autoStart { open(created, at: benchmark.startIndex) }
        // `--hm-open-feed <index>` opens the feed with overlays, for demos and screenshots.
        else if let index = benchmark.values["open-feed"].flatMap(Int.init) { open(created, at: index) }
        } catch { bootstrapError = error.localizedDescription }
    }
}
