import SwiftUI
import HotMicPlayer

/// The vertical feed plus the floating chrome that sits above it.
///
/// Chrome lives here rather than in the per-cell overlay because it must not
/// move, fade or rotate with the page transition.
struct FeedScreen: View {

    let controller: HMPlayer
    @Bindable var settings: DemoSettings
    let console: HMConsoleSink
    let muxBridge: DemoMuxBridge
    let onBack: () -> Void

    @State private var showsPanel = false
    @State private var shareNotice: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            HMVerticalFeedView(
                player: controller,
                transition: settings.transition,
                gravity: settings.gravity
            ) { item, snapshot in
                FeedOverlayView(controller: controller, item: item, snapshot: snapshot, settings: settings) { item in
                    shareNotice = "Share “\(item.title ?? item.id)” — wire your share sheet to HMOverlayLayout.Options.onShare"
                }
            }

            chrome
            #if DEBUG
            if DemoOptions().values["probe"] == "1" { RegressionFeedProbe(controller: controller, console: console) }
            #endif
            if let shareNotice {
                Text(shareNotice)
                    .font(DemoTheme.label(13, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: .capsule)
                    .padding(.horizontal, 24)
                    .transition(.opacity)
                    .task(id: shareNotice) {
                        try? await Task.sleep(for: .seconds(2.5))
                        withAnimation { self.shareNotice = nil }
                    }
            }

        }
        // A cover manages its own status bar, so this has to live here rather
        // than on the presenting view.
        .statusBarHidden()
        .demoPanel(
            isPresented: $showsPanel,
            settings: settings,
            console: console,
            muxBridge: muxBridge
        )
    }

    private var chrome: some View {
        VStack {
            HStack(spacing: 8) {
                ChromeButton(systemImage: "chevron.left", action: onBack)
                    .font(.system(size: 15, weight: .bold))

                Spacer()
                ChromeButton { showsPanel = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 15, weight: .semibold))
                        if console.entries.count > 0 {
                            Text("\(console.entries.count)")
                                .font(DemoTheme.metric(13, weight: .semibold))
                        }
                    }
                }
            }
            .padding(.horizontal, 12)

            Spacer()
        }
    }
}
