import SwiftUI
import HotMicPlayerUI
@_spi(Benchmark) import HotMicPlayer

struct BenchmarkScreen: View {
    var initialURL: String? = nil
    var autoStart = false
    @State private var url = ""
    @State private var runner = BenchmarkRunner()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let controller = runner.controller {
                if runner.showsSocialOverlay {
                    BenchmarkSocialSurface(player: controller, inline: runner.isInline).id(ObjectIdentifier(controller))
                } else if runner.isInline {
                    HMPlayerView(player: controller).id(ObjectIdentifier(controller))
                } else {
                    HMVerticalFeedView(player: controller) { item, snapshot in
                        BenchmarkEngagementOverlay(engagement: controller.engagement(for: item), mediaTime: snapshot.currentTime)
                    }.id(ObjectIdentifier(controller))
                }
            }
            VStack(spacing: 12) {
                if !runner.isRunning {
                    Text("HotMic benchmark").font(.title2.bold())
                    TextField("Grid configuration URL", text: $url)
                        .textFieldStyle(.roundedBorder).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("benchmark-grid-url")
                        .overlay(alignment: .trailing) {
                            Button { url = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.gray) }
                                .padding(6).accessibilityIdentifier("benchmark-grid-clear")
                        }
                    Button("Run grid") { runner.start(urlString: url) }
                        .accessibilityIdentifier("benchmark-grid-start")
                    Button("Close") { dismiss() }
                }
                Text(runner.progress).font(.caption).accessibilityIdentifier("benchmark-grid-progress")
                if let controller = runner.controller {
                    Text("\(controller.activeIndex)|\(controller.currentItem?.id ?? "")|\(controller.snapshot.timeToFirstFrame != nil ? "displayed" : "loading")")
                        .font(.caption2).accessibilityIdentifier("benchmark-status")
                }
                Spacer()
                if runner.isRunning { Button("Stop") { runner.cancel() } }
                if let failure = runner.failure { Text(failure).accessibilityIdentifier("benchmark-grid-error") }
                if runner.complete {
                    Text("Complete: \(runner.completedRuns), upload failures: \(runner.uploadsFailed)")
                        .accessibilityIdentifier("benchmark-grid-complete")
                }
                if let file = runner.localFiles.last { ShareLink("Share latest local run", item: file) }
            }
            .padding(24).background(alignment: .top) { Color.black.opacity(0.3).frame(height: runner.isRunning ? 120 : 240) }
        }
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in runner.controller?.isFeedVisible = phase == .active }
        .task {
            url = initialURL ?? UserDefaults.standard.string(forKey: "HMGridURL") ?? ""
            if autoStart, !url.isEmpty { runner.start(urlString: url) }
        }
    }
}

/// Exercises observation and comment loading during paired engagement on/off smoke cells.
private struct BenchmarkEngagementOverlay: View {
    let engagement: HMEngagement
    let mediaTime: TimeInterval
    var body: some View {
        VStack {
            Spacer()
            Text(engagement.previewComment(near: mediaTime)?.text ?? "")
            if let fire = engagement.reactionSummary(for: "🔥") {
                Text("Fire \(HMCountFormatter().string(from: fire.count))")
            }
        }.padding(.bottom, 80).foregroundStyle(.white).allowsHitTesting(false)
        .task {
            if engagement.supports(.loadComments) { try? await engagement.loadComments() }
        }
    }
}

/// Only the UI varies in paired smoke cells; both use the same observed engagement state.
private struct BenchmarkSocialSurface: View {
    let player: HMPlayer
    let inline: Bool
    @State private var data = BenchmarkSocialData()
    var body: some View {
        HMSocialPlayerView(player: player, surface: inline ? .inline : .feed) { item in
            data.adapter(player: player, item: item)
        }
        .task(id: player.currentItem?.id) {
            guard let item = player.currentItem else { return }
            let engagement = player.engagement(for: item)
            if engagement.supports(.loadComments) { try? await engagement.loadComments() }
        }
    }
}

@MainActor private final class BenchmarkSocialData {
    private var adapters: [String: HMEngagementSocialAdapter] = [:]
    func adapter(player: HMPlayer, item: HMMediaItem) -> HMEngagementSocialAdapter {
        if let adapter = adapters[item.id] { return adapter }
        let adapter = HMEngagementSocialAdapter(engagement: player.engagement(for: item), metadata: HMSocialContent(
            title: "A moment to share", description: "Watch, react and join the conversation.", hashtags: ["Highlights"], community: "Community"))
        adapters[item.id] = adapter
        return adapter
    }
}
