#if DEBUG
import SwiftUI
@_spi(Benchmark) import HotMicPlayer

/// Both surfaces use the same host-owned skip UI and ad-state suppression.
struct AdsLabScreen: View {
    @State private var player = HMPlayer(configuration: HMPlayerConfiguration(startsMuted: true))
    @State private var inline = DemoOptions().values["ads-inline"] == "1"
    @State private var status = "Preparing offline media"
    @State private var error: String?
    @Environment(\.scenePhase) private var phase
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if inline {
                HMPlayerView(player: player, aspectRatio: nil) { _, _ in chrome }.ignoresSafeArea()
            } else {
                HMVerticalFeedView(player: player) { _, _ in chrome }
            }
            VStack {
                HStack {
                    Button(inline ? "Feed" : "Standalone") { inline.toggle() }.accessibilityIdentifier("ads-surface")
                    Spacer()
                    Button("Next") { player.next() }.accessibilityIdentifier("ads-next")
                }
                Text(status).font(.caption.monospaced()).accessibilityIdentifier("ads-status")
                if let error { Text(error) }
                Spacer()
            }.padding().foregroundStyle(.white)
        }
        .preferredColorScheme(.dark)
        .task {
            do {
                let ad = try await socialVideoFixture(landscape: true, name: "ads-preroll", seconds: 6)
                let content = try await socialVideoFixture(landscape: false, name: "ads-content")
                let provider = DemoAdProvider(preRollURL: ad)
                if let watched = Double(DemoOptions().values["ads-companion-watched"] ?? "") { provider.companionTrigger.watchedTime = watched }
                if let countdown = Double(DemoOptions().values["ads-companion-countdown"] ?? "") { provider.companionTrigger.countdown = countdown }
                player.adBreakProvider = provider
                if DemoOptions().values["ads-block-swipe"] == "1" { player.configuration.allowsSwipeDuringAds = false }
                if let duration = Double(DemoOptions().values["ads-max-duration"] ?? "") { player.configuration.adBreakMaxDuration = duration }
                if let timeout = Double(DemoOptions().values["ads-no-progress"] ?? "") { player.configuration.adNoProgressTimeout = timeout }
                let start = Int(DemoOptions().values["start-index"] ?? "0") ?? 0
                let events = player.events
                player.replaceAll(["url-ad", "host-ad", "slow-ad", "content", "hung-ad", "endless-ad", "companion-ad", "after-companion"].map {
                    HMMediaItem(id: $0, url: content, title: $0, aspectRatio: 9.0 / 16)
                }, startAt: start)
                await player.start()
                await diagnostics(events: events)
            } catch { self.error = error.localizedDescription }
        }
        .onChange(of: phase) { _, phase in player.isFeedVisible = phase == .active }
        .onDisappear { if !player.isFullscreen { player.teardown() } }
    }
    private var chrome: some View {
        VStack {
            Spacer()
            if player.companionState == .countdown, let countdown = player.companionCountdown {
                Text("Ad in \(Int(countdown.estimatedRemaining(at: ProcessInfo.processInfo.systemUptime).rounded(.up)))").accessibilityIdentifier("ads-companion-countdown")
            }
            if player.companionState.isPresented {
                Text("Companion ad").accessibilityIdentifier("ads-companion")
                Button(player.isCompanionMuted ? "Unmute companion" : "Mute companion") { player.isCompanionMuted.toggle() }
                    .accessibilityIdentifier("ads-companion-mute").hmExcludedHitArea()
            }
            if player.adState.isActive {
                Text("Advertisement").accessibilityIdentifier("ads-active")
                if case .playing = player.adState {
                    let progress = player.adProgress
                    Text("\(progress.elapsed, specifier: "%.1f") / \(progress.duration, specifier: "%.1f")")
                }
                Button("Skip ad") { player.skipAd() }.accessibilityIdentifier("ads-skip").hmExcludedHitArea()
            } else {
                Button("Comments") { }.accessibilityIdentifier("ads-comments").hmExcludedHitArea()
                Text("Comment preview").accessibilityIdentifier("ads-preview")
                Button("Open squeezeback") { }.accessibilityIdentifier("ads-squeeze").hmExcludedHitArea()
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.bottom, 100).foregroundStyle(.white)
    }
    @MainActor private func diagnostics(events: AsyncStream<HMPlayerEvent>) async {
        #if DEBUG
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let log = documents.appendingPathComponent("ads-events.jsonl")
        try? Data().write(to: log)
        let eventTask = Task { @MainActor in
            for await event in events {
                guard let data = try? JSONSerialization.data(withJSONObject: ["time": ProcessInfo.processInfo.systemUptime, "event": String(describing: event)]),
                      let handle = try? FileHandle(forWritingTo: log) else { continue }
                defer { try? handle.close() }; try? handle.seekToEnd(); try? handle.write(contentsOf: data + Data([10]))
            }
        }
        defer { eventTask.cancel() }
        // Commands belong to this launch; do not replay a previous debugging session.
        var lastCommand = (try? String(contentsOf: documents.appendingPathComponent("ads-command.txt"))) ?? ""
        while !Task.isCancelled {
            status = "\(player.currentItem?.id ?? "") | \(player.adState)"
            let value: [String: Any] = ["item": player.currentItem?.id ?? "", "ad": String(describing: player.adState),
                "active": player.adState.isActive, "time": player.snapshot.currentTime,
                "ttff": player.snapshot.timeToFirstFrame ?? -1, "ready": player.snapshot.readinessTier.rawValue,
                "prepared": player.preparedItemIdentities, "swipeBlocked": player.isAdSwipeBlocked,
                "contentRate": player.snapshot.state.rawValue, "progress": player.adProgress.elapsed,
                "feedVisible": player.isFeedVisible, "companion": String(describing: player.companionState),
                "companionRemaining": player.companionCountdown?.remaining ?? -1, "companionMuted": player.isCompanionMuted]
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) { try? data.write(to: documents.appendingPathComponent("ads-state.json"), options: .atomic) }
            if let command = try? String(contentsOf: documents.appendingPathComponent("ads-command.txt")), command != lastCommand {
                lastCommand = command
                switch command.split(separator: "|").first {
                case "next": player.next()
                case "swipe": player.requestPage(at: player.activeIndex + 1)
                case "skip": player.skipAd()
                case "pause": player.pause()
                case "play": player.play()
                case "hide": player.isFeedVisible = false
                case "show": player.isFeedVisible = true
                case "previous": player.previous()
                case "remove":
                    player.configuration.removedCurrentPolicy = .finishThenAdvance
                    if let id = player.currentItem?.id { player.remove(ids: [id]) }
                case "standalone": inline = true
                case "feed": inline = false
                case "companion-skip": player.skipCompanion()
                case "companion-dismiss": player.dismissCompanion()
                case "companion-unmute": player.isCompanionMuted = false
                case "companion-mute": player.isCompanionMuted = true
                default: break
                }
            }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        #endif
    }
}

#endif
