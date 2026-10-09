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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            HMVerticalFeedView(
                player: controller,
                transition: settings.transition,
                gravity: settings.gravity
            ) { item, snapshot in
                FeedOverlayView(
                    item: item,
                    snapshot: snapshot,
                    timeline: controller.timeline(for: item),
                    isActive: controller.currentItem?.id == item.id,
                    settings: settings,
                    poolBusy: controller.preparedItemCount,
                    poolSize: controller.configuration.poolSize,
                    isMuted: controller.isMuted,
                    onTogglePlayPause: { controller.togglePlayPause() },
                    onToggleMute: { controller.toggleMute() },
                    onSeek: { controller.seek(toProgress: $0) },
                    onScrubStateChange: { controller.isInteracting = $0 }
                )
            }

            chrome
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
