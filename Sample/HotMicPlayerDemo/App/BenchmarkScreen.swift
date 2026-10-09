import SwiftUI
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
                HMVerticalFeedView(player: controller)
                    .id(ObjectIdentifier(controller))
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
