#if DEBUG
import SwiftUI
import AVFAudio
@_spi(Benchmark) import HotMicPlayer

/// Opt-in native UI acceptance only. No grid, runner, export or upload behavior.
struct RegressionFeedProbe: View {
    let controller: HMPlayer
    let console: HMConsoleSink
    var body: some View {
        VStack {
            Text(controller.isInteracting ? "interacting" : "idle").accessibilityIdentifier("interaction-state")
            Text(console.entries.filter { $0.kind == .viewStart }.reversed().map { $0.event.itemID }.joined(separator: ","))
                .accessibilityIdentifier("probe-starts")
            Text(controller.preparedItemIdentities.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: ","))
                .accessibilityIdentifier("probe-assignments")
            Text("\(controller.activeIndex)|\(controller.currentItem?.id ?? "")|\(controller.snapshot.timeToFirstFrame != nil ? "displayed" : "loading")|\(controller.snapshot.duration)")
                .accessibilityIdentifier("regression-status")
            Spacer()
        }.font(.system(size: 8)).allowsHitTesting(false)
        .task { await RegressionCommands.advance(controller) }
    }
}

@MainActor enum RegressionSupport {
    static func interactions() -> any HMInteractionSource { HMMockInteractionSource() }
    static func source() async throws -> any HMPlaylistSource {
        if DemoOptions().values["manifest-url"] != nil { return try await DemoOptions().dataSource() }
        let vertical = try await socialVideoFixture(landscape: false, name: "regression-portrait")
        let horizontal = try await socialVideoFixture(landscape: true, name: "regression-landscape")
        return HMStaticPlaylistSource(items: (0..<6).map {
            HMMediaItem(id: "regression-\($0)", url: $0.isMultiple(of: 2) ? vertical : horizontal,
                title: "Generated regression clip \($0)", aspectRatio: $0.isMultiple(of: 2) ? 9.0 / 16 : 16.0 / 9)
        }, pageSize: 6, loopsForever: false)
    }
}

/// Walkthrough probe: the host posts `com.hotmic.probe.next` (`xcrun simctl spawn <id> notifyutil -p ...`)
/// to page forward while a UI test is holding a touch, which XCUITest can't do on its own.
enum RegressionCommands {
    @MainActor static func advance(_ controller: HMPlayer) async {
        var commands = ["next", "previous", "reconcile", "metadata", "remove-current", "remove-next", "insert-next", "append",
            "jump-last", "finish-policy", "advance-policy", "pause", "play", "seek", "seek-end", "hide", "show", "fullscreen", "exit-fullscreen", "captions", "teardown"]
        #if DEBUG
        commands += ["inspect", "interrupt-began", "interrupt-end-paused", "media-reset", "seek-middle", "background", "foreground"]
        #endif
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
            #if DEBUG
            case "inspect": break
            case "background": NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
            case "foreground": NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            case "interrupt-began": NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
            case "interrupt-end-paused": NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                    AVAudioSessionInterruptionOptionKey: 0])
            case "media-reset": NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
            case "seek-middle": controller.seek(to: controller.snapshot.duration * 0.65)
            #endif
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
                var diagnostics: [String: String] = [:]
                #if DEBUG
                diagnostics["last_event"] = String(describing: controller.lastEvent)
                diagnostics["audio_session_configurations"] = String(controller.audioSessionConfigurationCount)
                #endif
                let event = HMPlaybackEvent(kind: .transfer, itemID: item.id,
                    metrics: ["prepared_item_count": Double(controller.preparedItemCount), "playlist_revision": Double(controller.playlistRevision),
                        "paused": controller.snapshot.state == .paused ? 1 : 0,
                        "frame_ready": controller.snapshot.isFrameReady ? 1 : 0,
                        "position_s": controller.snapshot.currentTime],
                    properties: ["probe_command": command, "playback_state": String(describing: controller.snapshot.state), "assignments": String(decoding: assignments, as: UTF8.self)].merging(diagnostics) { _, latest in latest })
                for sink in controller.analytics.sinks { sink.handle(event, item: item) }
            }
        }
    }
    private enum Box { nonisolated(unsafe) static var continuation: AsyncStream<String>.Continuation? }
}

#endif
