#if DEBUG
import SwiftUI
import Observation
@_spi(Benchmark) import HotMicPlayer

/// Mixed MP4/HLS feed and a regular inline player using exactly the same engine.
/// Launch with --hm-horizontal-lab 1 and optionally --hm-manifest-url <generated manifest>.
struct RegressionHorizontalScreen: View {
    @StateObject private var owner: DemoPlayerOwner
    private var player: HMPlayer { owner.player }
    @State private var inline = DemoOptions().values["horizontal-inline"] == "1"
    @State private var hostSheet = false
    @State private var error: String?
    @State private var counters = HorizontalCounters()
    private let options = DemoOptions()

    init() {
        var configuration = HMPlayerConfiguration(startsMuted: true)
        configuration.presentation = .fitWithBlurredBackdrop
        configuration.followsDeviceRotation = true
        _owner = StateObject(wrappedValue: DemoPlayerOwner(player: HMPlayer(configuration: configuration)))
    }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if inline {
                VStack(spacing: 24) {
                    Text("Inline 16:9 player").font(.title2)
                    HMPlayerView(player: player) { _, snapshot in fullscreenCaption(snapshot) }
                    Text("Same engine · next / previous · fullscreen").font(.caption)
                }
            } else {
                HMVerticalFeedView(player: player) { _, snapshot in
                    fullscreenCaption(snapshot)
                    GeometryReader { _ in
                        Rectangle().stroke(.white.opacity(0.5), lineWidth: 1)
                            .frame(width: snapshot.videoFrame.width, height: snapshot.videoFrame.height)
                            .position(x: snapshot.videoFrame.midX, y: snapshot.videoFrame.midY)
                            .allowsHitTesting(false)
                    }
                }
            }
            VStack(spacing: 8) {
                Text("Horizontal video").font(.headline)
                Text("\(player.currentItem?.id ?? "loading") · \(player.snapshot.aspectRatio.map { String(format: "%.3f", $0) } ?? "unknown") · \(player.isFullscreen ? "fullscreen" : "inline")")
                    .font(.caption).accessibilityIdentifier("horizontal-status")
                Text("TTFF \(player.snapshot.timeToFirstFrame.map { String(format: "%.0f ms", $0 * 1000) } ?? "pending") · stalls \(player.snapshot.stallCount)")
                    .font(.caption).accessibilityIdentifier("horizontal-ttff")
                Text("\(player.snapshot.activationID)|\(player.preparedItemIdentities[player.currentItem?.id ?? ""] ?? "")|\(counters.frames)|\(counters.stalls)")
                    .font(.system(size: 8)).accessibilityIdentifier("horizontal-evidence")
                Text("orientation=\(UIDevice.current.orientation.rawValue) notifications=\(UIDevice.current.isGeneratingDeviceOrientationNotifications) app=\(UIApplication.shared.applicationState.rawValue) scenes=\(UIApplication.shared.connectedScenes.map { $0.activationState.rawValue }) visible=\(player.isFeedVisible) fullscreen=\(player.isFullscreen) position=\(player.snapshot.currentTime)")
                    .font(.system(size: 8)).accessibilityIdentifier("horizontal-runtime")
                if let error { Text(error) }
                Spacer()
                HStack {
                    Button("Previous") { player.previous() }
                    Button("Next") { player.next() }
                    Button("Fullscreen") { player.enterFullscreen() }.accessibilityIdentifier("horizontal-fullscreen")
                    Button(inline ? "Feed" : "Inline") { inline.toggle() }.accessibilityIdentifier("horizontal-inline")
                }
                Button("Host sheet") { hostSheet = true }.accessibilityIdentifier("horizontal-sheet")
                HStack {
                    ForEach([HMVideoPresentation.automatic, .fill, .fit, .fitWithBlurredBackdrop, .fitWithColor], id: \.self) { policy in
                        Button(label(policy)) {
                            player.configuration.presentation = policy
                            player.configuration.backdropColor = HMVideoBackdropColor(red: 0.06, green: 0.12, blue: 0.25)
                        }.accessibilityIdentifier("horizontal-\(label(policy))")
                    }
                }
            }
            .padding().buttonStyle(.bordered).font(.caption).foregroundStyle(.white)
        }
        .sheet(isPresented: $hostSheet) {
            VStack(spacing: 24) {
                Text("Host sheet").accessibilityIdentifier("horizontal-host-sheet")
                Button("Sheet fullscreen") { player.enterFullscreen() }.accessibilityIdentifier("sheet-fullscreen")
                Button("Close sheet") { hostSheet = false }.accessibilityIdentifier("close-host-sheet")
            }.presentationDetents([.medium])
        }
        .task {
            guard player.items.isEmpty else { return }
            do {
                player.analytics.add(counters)
                player.playlistSource = try await options.dataSource()
                await player.start()
                if options.startIndex > 0, player.items.indices.contains(options.startIndex) { player.jump(toID: player.items[options.startIndex].id) }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
        .onAppear { player.isFeedVisible = true }
        .onDisappear { if !player.isFullscreen { player.isFeedVisible = false } }
    }
    private func fullscreenCaption(_ snapshot: HMPlaybackSnapshot) -> some View {
        VStack {
            Spacer()
            Text("Partner captions · \(Int(snapshot.videoFrame.width)) × \(Int(snapshot.videoFrame.height))")
                .font(.caption).padding().background(.black.opacity(0.5))
                .accessibilityIdentifier("horizontal-caption")
        }.allowsHitTesting(false)
    }
    private func label(_ policy: HMVideoPresentation) -> String {
        switch policy {
        case .automatic: return "Auto"
        case .fill: return "Fill"
        case .fit: return "Fit"
        case .fitWithBlurredBackdrop: return "Blur"
        case .fitWithColor: return "Color"
        }
    }
}

@MainActor @Observable private final class HorizontalCounters: HMAnalyticsSink {
    let sinkName = "horizontal-continuity"
    private(set) var frames = 0
    private(set) var stalls = 0
    func handle(_ event: HMPlaybackEvent, item: HMMediaItem) {
        if event.kind == .firstFrame { frames += 1 }
        if event.kind == .rebufferStart { stalls += 1 }
    }
}

#endif
