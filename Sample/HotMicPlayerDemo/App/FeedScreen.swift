import SwiftUI
@_spi(Benchmark) import HotMicPlayer

/// The vertical feed plus the floating chrome that sits above it.
///
/// Chrome lives here rather than in the per-cell overlay because it must not
/// move, fade or rotate with the page transition.
struct FeedScreen: View {

    let controller: HMPlayer
    @Bindable var settings: DemoSettings
    let console: HMConsoleSink
    let muxBridge: HMLoggingMuxBridge
    let onBack: () -> Void
    var fileSink: HMJSONLFileSink? = nil
    var isBenchmark = false
    @State private var exportReady = false
    @State private var exportError: String?

    @State private var showsPanel = false
    @State private var shareNotice: String?
    private let probes = BenchmarkOptions().values["probe"] == "1"

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
            if probes {
                // Walkthrough probe (`--hm-probe 1`): lets UI tests see interaction deferral.
                VStack {
                    Text(controller.isInteracting ? "interacting" : "idle")
                        .font(.system(size: 9)).foregroundStyle(.white.opacity(0.6))
                        .accessibilityIdentifier("interaction-state")
                    Spacer()
                }
                .allowsHitTesting(false)
                .task { await HMProbeNotifications.advance(controller) }
            }
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
            if isBenchmark {
                VStack {
                    Text("\(controller.activeIndex)|\(controller.currentItem?.id ?? "")|\(controller.snapshot.timeToFirstFrame != nil ? "displayed" : "loading")|\(controller.snapshot.duration)")
                        .font(.system(size: 10)).accessibilityIdentifier("benchmark-status")
                    Spacer()
                    if let exportError { Text(exportError) }
                    if exportReady { Text("Complete").accessibilityIdentifier("benchmark-complete") }
                    Button("Finish run") {
                        Task {
                            await controller.finishRun()
                            do { try await fileSink?.flush(); exportReady = true }
                            catch { exportError = error.localizedDescription }
                        }
                    }.accessibilityIdentifier("benchmark-finish")
                }.padding(.vertical, 32)
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
                if let fileSink {
                    ShareLink(item: fileSink.fileURL) { Image(systemName: "square.and.arrow.up") }
                        .simultaneousGesture(TapGesture().onEnded { Task { try? await fileSink.flush() } })
                }
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

/// Walkthrough probe: the host posts `com.hotmic.probe.next` (`xcrun simctl spawn <id> notifyutil -p ...`)
/// to page forward while a UI test is holding a touch, which XCUITest can't do on its own.
enum HMProbeNotifications {
    @MainActor static func advance(_ controller: HMPlayer) async {
        let name = "com.hotmic.probe.next" as CFString
        let stream = AsyncStream<Void> { continuation in
            Box.continuation = continuation
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil,
                { _, _, _, _, _ in Box.continuation?.yield() }, name, nil, .deliverImmediately)
        }
        for await _ in stream { controller.next() }
    }
    private enum Box { nonisolated(unsafe) static var continuation: AsyncStream<Void>.Continuation? }
}
