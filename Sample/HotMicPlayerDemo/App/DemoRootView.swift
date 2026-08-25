import SwiftUI
import HotMicPlayer

/// Hosts the two screens and owns everything long-lived: the feed controller,
/// the analytics sinks and the runtime settings.
struct DemoRootView: View {

    @State private var settings = DemoSettings()
    @State private var console = HMConsoleSink()
    @State private var muxBridge = HMLoggingMuxBridge()
    @State private var controller: HMFeedController?

    @State private var isFeedPresented = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
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
                ProgressView().tint(.white)
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
                    onBack: { close(controller) }
                )
            }
        }
        .tint(DemoTheme.accent)
        .preferredColorScheme(.dark)
        .task { bootstrapIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            // Only the feed screen plays. Backgrounding while browsing the
            // playlist must not start anything.
            controller?.isFeedVisible = isFeedPresented && phase == .active
        }
    }

    // MARK: - Navigation

    private func open(_ controller: HMFeedController, at index: Int) {
        // Index first, then visibility: `setActiveIndex` only promotes an item
        // to playing when the feed is on screen, so this ordering gives the
        // selected clip a clean activation (and an honest TTFF).
        controller.setActiveIndex(index, reason: .programmatic)
        isFeedPresented = true
        controller.isFeedVisible = true
    }

    private func close(_ controller: HMFeedController) {
        controller.isFeedVisible = false
        isFeedPresented = false
    }

    // MARK: - Wiring

    private func bootstrapIfNeeded() {
        guard controller == nil else { return }

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

        let created = HMFeedController(
            dataSource: DemoContent.dataSource,
            configuration: settings.preset.configuration,
            analytics: hub
        )
        // Warm content while the viewer browses the playlist, but do not play.
        created.isFeedVisible = false
        settings.applyConfiguration = { [weak created] configuration in
            created?.configuration = configuration
        }
        settings.rebuildConfiguration()
        controller = created
    }
}
