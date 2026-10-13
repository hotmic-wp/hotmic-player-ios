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
                    Text(console.entries.filter { $0.kind == .viewStart }.reversed().map { $0.event.itemID }.joined(separator: ","))
                        .font(.system(size: 8)).accessibilityIdentifier("probe-starts")
                    Text(controller.preparedItemIdentities.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: ","))
                        .font(.system(size: 8)).accessibilityIdentifier("probe-assignments")
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
        let commands = ["next", "previous", "reconcile", "metadata", "remove-current", "remove-next", "insert-next", "append",
            "jump-last", "finish-policy", "advance-policy", "pause", "play", "seek", "seek-end", "hide", "show", "fullscreen", "exit-fullscreen", "captions", "teardown"]
        let names = commands.map { "com.hotmic.probe." + $0 }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let stream = AsyncStream<String> { continuation in
            Box.continuation = continuation
            for name in names {
                CFNotificationCenterAddObserver(center, nil, { _, _, name, _, _ in
                    if let name { Box.continuation?.yield(name.rawValue as String) }
                }, name as CFString, nil, .deliverImmediately)
            }
        }
        defer {
            for name in names { CFNotificationCenterRemoveObserver(center, nil, CFNotificationName(name as CFString), nil) }
            Box.continuation = nil
        }
        var sequence = 0
        func copy(_ item: HMMediaItem, id: String? = nil, title: String? = nil) -> HMMediaItem {
            HMMediaItem(id: id ?? item.id, source: item.source, posterURL: item.posterURL, title: title ?? item.title,
                author: item.author, durationHint: item.durationHint, metadata: item.metadata, aspectRatio: item.aspectRatio,
                presentation: item.presentation, captionSources: item.captionSources)
        }
        for await name in stream {
            let command = String(name.dropFirst("com.hotmic.probe.".count))
            switch command {
            case "next": controller.next()
            case "previous": controller.previous()
            case "reconcile":
                if let current = controller.currentItem {
                    let history = Set(controller.items.prefix(controller.activeIndex + 1).map(\.id))
                    var upcoming = controller.items.filter { !history.contains($0.id) }
                    if upcoming.count > 1 { upcoming.swapAt(0, 1) }
                    controller.reconcile([current] + upcoming)
                }
            case "metadata": controller.reconcile(controller.items.map { copy($0, title: "Updated " + $0.id) })
            case "remove-current": if let id = controller.currentItem?.id { controller.remove(ids: [id]) }
            case "remove-next": if controller.items.indices.contains(controller.activeIndex + 1) { controller.remove(ids: [controller.items[controller.activeIndex + 1].id]) }
            case "insert-next", "append":
                if let current = controller.currentItem {
                    sequence += 1; let entry = copy(current, id: "probe-entry-\(sequence)")
                    if command == "insert-next" { controller.insertNext([entry]) } else { controller.append([entry]) }
                }
            case "jump-last": if let id = controller.items.last?.id { controller.jump(toID: id) }
            case "finish-policy": controller.configuration.removedCurrentPolicy = .finishThenAdvance
            case "advance-policy": controller.configuration.removedCurrentPolicy = .advanceNow
            case "pause": controller.pause()
            case "play": controller.play()
            case "seek": controller.seek(to: 0)
            case "seek-end": controller.seek(to: max(0, controller.snapshot.duration - 0.5))
            case "hide": controller.isFeedVisible = false
            case "show": controller.isFeedVisible = true
            case "fullscreen": controller.enterFullscreen()
            case "exit-fullscreen": controller.exitFullscreen()
            case "captions": controller.captionsEnabled.toggle()
            case "teardown": controller.teardown()
            default: break
            }
            if let item = controller.currentItem {
                let assignments = (try? JSONSerialization.data(withJSONObject: controller.preparedItemIdentities, options: .sortedKeys)) ?? Data()
                let event = HMPlaybackEvent(kind: .transfer, itemID: item.id,
                    metrics: ["prepared_item_count": Double(controller.preparedItemCount), "playlist_revision": Double(controller.playlistRevision)],
                    properties: ["probe_command": command, "assignments": String(decoding: assignments, as: UTF8.self)])
                for sink in controller.analytics.sinks { sink.handle(event, item: item) }
            }
        }
    }
    private enum Box { nonisolated(unsafe) static var continuation: AsyncStream<String>.Continuation? }
}
