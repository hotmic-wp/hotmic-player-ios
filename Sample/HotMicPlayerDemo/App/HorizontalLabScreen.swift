import SwiftUI
import Observation
@_spi(Benchmark) import HotMicPlayer

/// Mixed MP4/HLS feed and a regular inline player using exactly the same engine.
/// Launch with --hm-horizontal-lab 1 and optionally --hm-manifest-url <generated manifest>.
struct HorizontalLabScreen: View {
    @State private var player: HMPlayer
    @State private var inline = BenchmarkOptions().values["horizontal-inline"] == "1"
    @State private var sink: HMJSONLFileSink?
    @State private var error: String?
    @State private var lastCommand = ""
    @State private var counters = HorizontalCounters()
    @State private var evidenceTask: Task<Void, Never>?
    private let options = BenchmarkOptions()

    init() {
        var configuration = HMPlayerConfiguration(startsMuted: true)
        configuration.presentation = .fitWithBlurredBackdrop
        configuration.followsDeviceRotation = true
        _player = State(initialValue: HMPlayer(configuration: configuration))
    }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if inline {
                VStack(spacing: 24) {
                    Text("Inline 16:9 player").font(.title2)
                    HMPlayerView(player: player)
                    Text("Same engine · next / previous · fullscreen").font(.caption)
                }
            } else {
                HMVerticalFeedView(player: player) { _, snapshot in
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
                if let error { Text(error) }
                Spacer()
                HStack {
                    Button("Previous") { player.previous() }
                    Button("Next") { player.next() }
                    Button("Fullscreen") { player.enterFullscreen() }.accessibilityIdentifier("horizontal-fullscreen")
                    Button(inline ? "Feed" : "Inline") { inline.toggle() }.accessibilityIdentifier("horizontal-inline")
                }
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
        .task {
            do {
                guard sink == nil else { return }
                let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("horizontal-lab.jsonl")
                let createdSink = try HMJSONLFileSink(fileURL: file, runID: "horizontal-lab", configuration: player.configuration,
                    format: "mixed", network: "local", script: "manual", buildSHA: "local")
                sink = createdSink; player.analytics.add(createdSink); player.analytics.add(counters)
                player.playlistSource = try await options.dataSource()
                await player.start()
                if options.startIndex > 0, player.items.indices.contains(options.startIndex) { player.jump(toID: player.items[options.startIndex].id) }
                evidenceTask = Task { @MainActor in
                    while !Task.isCancelled {
                        #if DEBUG
                        // Local simulator control file: action|unique nonce, never a production integration API.
                        let commandFile = file.deletingLastPathComponent().appendingPathComponent("horizontal-command.txt")
                        if let command = try? String(contentsOf: commandFile, encoding: .utf8), command != lastCommand {
                            lastCommand = command
                            applyCommand(String(command.split(separator: "|")[0]))
                        }
                        #endif
                        let snapshot = player.snapshot
                        let evidence: [String: Any] = ["time": ProcessInfo.processInfo.systemUptime, "id": player.currentItem?.id ?? "",
                            "fullscreen": player.isFullscreen, "interacting": player.isInteracting, "inlineSurface": inline, "assignments": player.preparedItemIdentities,
                            "activation": snapshot.activationID, "playhead": snapshot.currentTime, "stalls": snapshot.stallCount,
                            "ttff": snapshot.timeToFirstFrame ?? -1, "aspect": snapshot.aspectRatio ?? 0,
                            "firstFrameEvents": counters.frames, "stallEvents": counters.stalls]
                        let url = file.deletingLastPathComponent().appendingPathComponent("horizontal-state.json")
                        try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]).write(to: url, options: .atomic)
                        try? await createdSink.flush()
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    private func applyCommand(_ command: String) {
        switch command {
        case "enter": player.enterFullscreen()
        case "exit": player.exitFullscreen()
        case "inline": inline = true
        case "feed": inline = false
        case "next": player.next()
        case "previous": player.previous()
        default:
            if let policy = HMVideoPresentation(rawValue: command) {
                player.configuration.presentation = policy
                player.configuration.backdropColor = HMVideoBackdropColor(red: 0.06, green: 0.12, blue: 0.25)
            }
        }
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
