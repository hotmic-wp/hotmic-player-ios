#if DEBUG
import SwiftUI
import AVFAudio
import MediaAccessibility
@_spi(Benchmark) import HotMicPlayer

/// Local, generated fixtures: use the generic public regression fixture helper first.
struct CaptionsAudioLabScreen: View {
    @State private var player: HMPlayer = {
        let options = DemoOptions()
        var configuration = HMPlayerConfiguration()
        configuration.managesAudioSession = options.values["host-audio"] != "1"
        configuration.allowsBackgroundAudio = options.values["background-audio"] == "1"
        return HMPlayer(configuration: configuration)
    }()
    @State private var message = "Preparing caption fixtures"
    @State private var status = ""
    @State private var originalDisplayType: MACaptionAppearanceDisplayType?
    private let options = DemoOptions()
    var body: some View {
        HMVerticalFeedView(player: player) { item, _ in
            CaptionLabSafeChrome {
            VStack {
                HStack {
                    Button(player.captionsEnabled ? "CC on" : "CC off") { player.captionsEnabled.toggle() }.accessibilityIdentifier("lab-cc")
                    Button(player.isMuted ? "Unmute" : "Mute") { player.toggleMute() }
                    Button("Play/Pause") { player.togglePlayPause() }
                    Button("Next") { player.next() }
                }.padding().hmExcludedHitArea()
                Text(status).font(.caption.monospaced()).accessibilityIdentifier("caption-status").hmExcludedHitArea()
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading) {
                        Text(item.title ?? "").font(.title2)
                        Text(message).font(.caption)
                        Text("Reserved metadata region").accessibilityIdentifier("caption-reservation")
                    }.padding().frame(maxWidth: .infinity, minHeight: 150, alignment: .bottomLeading).hmExcludedHitArea()
                    VStack {
                        Button("English") { player.selectCaption("en") }
                        Button("System CC") { player.captionPreference = nil }
                        #if DEBUG
                        Button("Interrupt") { post(AVAudioSession.interruptionNotification, [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]) }
                        Button("Resume") { post(AVAudioSession.interruptionNotification, [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue, AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue]) }
                        Button("Unplug") { post(AVAudioSession.routeChangeNotification, [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue]) }
                        #endif
                    }.padding().hmExcludedHitArea()
                }
            }.foregroundStyle(.white)
            }
        }
        .hmCaptionInsets(HMVideoInsets(top: 120, bottom: 30))
        .task {
            let origin = URL(string: options.values["lab-origin"] ?? "http://127.0.0.1:18433")!
            let sidecar = Bundle.main.url(forResource: "demo.en", withExtension: "vtt") ?? origin.appendingPathComponent("fixture/en.vtt")
            if options.values["captions"] == "1" { player.captionsEnabled = true }
            if options.values["host-audio"] == "1" {
                player.configuration.managesAudioSession = false
                #if DEBUG
                // The host deliberately chooses a different category to make SDK ownership violations visible.
                try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
                #endif
            }
            if options.values["background-audio"] == "1" { player.configuration.allowsBackgroundAudio = true }
            let events = player.events
            player.replaceAll([
                HMMediaItem(id: "caption-mp4", url: origin.appendingPathComponent("fixture/clip.mp4"), title: "MP4 · sidecar WebVTT", captionSources: ["en": sidecar, "es": origin.appendingPathComponent("fixture/es.vtt")]),
                HMMediaItem(id: "caption-hls", url: origin.appendingPathComponent(options.values["selection-fixture"] == "1" ? "fixture/selection-master.m3u8" : "fixture/master.m3u8"), title: "HLS · AVMediaSelection subtitles")
            ])
            await player.start()
            await diagnostics(events)
        }
        .onDisappear {
            if let originalDisplayType { MACaptionAppearanceSetDisplayType(.user, originalDisplayType) }
            if !player.isFullscreen { player.teardown() }
        }
    }
    private func post(_ name: Notification.Name, _ values: [String: Any] = [:]) {
        NotificationCenter.default.post(name: name, object: AVAudioSession.sharedInstance(), userInfo: values)
    }
    @MainActor private func diagnostics(_ events: AsyncStream<HMPlayerEvent>) async {
        #if DEBUG
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let log = documents.appendingPathComponent("caption-events.jsonl")
        try? Data().write(to: log)
        let eventTask = Task { @MainActor in
            for await event in events {
                guard let data = try? JSONSerialization.data(withJSONObject: ["time": ProcessInfo.processInfo.systemUptime, "event": String(describing: event)]), let handle = try? FileHandle(forWritingTo: log) else { continue }
                defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data + Data([10]))
            }
        }
        defer { eventTask.cancel() }
        var lastCommand = (try? String(contentsOf: documents.appendingPathComponent("caption-command.txt"))) ?? ""
        while !Task.isCancelled {
            status = "\(player.currentItem?.id ?? "") · \(player.snapshot.state) · CC \(player.captionsEnabled) · \(player.availableCaptionLanguages.joined(separator: ","))"
            let elements = accessibilityEvidence()
            let value: [String: Any] = ["item": player.currentItem?.id ?? "", "state": player.snapshot.state.rawValue,
                "time": player.snapshot.currentTime, "ttff": player.snapshot.timeToFirstFrame ?? -1,
                "captions": player.captionsEnabled, "systemCaptions": MACaptionAppearanceGetDisplayType(.user) == .alwaysOn,
                "languages": player.availableCaptionLanguages, "muted": player.isMuted, "elements": elements, "command": lastCommand,
                "managesAudioSession": player.configuration.managesAudioSession, "sessionConfigurations": player.audioSessionConfigurationCount,
                "sessionCategory": AVAudioSession.sharedInstance().category.rawValue, "sessionMode": AVAudioSession.sharedInstance().mode.rawValue]
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) { try? data.write(to: documents.appendingPathComponent("caption-state.json"), options: .atomic) }
            if let command = try? String(contentsOf: documents.appendingPathComponent("caption-command.txt")), command != lastCommand {
                lastCommand = command
                switch command.split(separator: "|").first {
                case "cc": player.captionsEnabled.toggle()
                case "system": player.captionPreference = nil
                case "system-on", "system-off":
                    if originalDisplayType == nil { originalDisplayType = MACaptionAppearanceGetDisplayType(.user) }
                    MACaptionAppearanceSetDisplayType(.user, command.hasPrefix("system-on") ? .alwaysOn : .forcedOnly)
                case "swipe": player.requestPage(at: player.activeIndex == 0 ? 1 : 0)
                case "next": player.next()
                case "previous": player.previous()
                case "pause": player.pause()
                case "play": player.play()
                case "language-missing": player.selectCaption("zz")
                case "began-suspended": post(AVAudioSession.interruptionNotification, [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue, AVAudioSessionInterruptionReasonKey: AVAudioSession.InterruptionReason.appWasSuspended.rawValue])
                case "began-was-suspended": post(AVAudioSession.interruptionNotification, [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue, AVAudioSessionInterruptionWasSuspendedKey: true])
                case "began": post(AVAudioSession.interruptionNotification, [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
                case "ended", "ended-no-resume": post(AVAudioSession.interruptionNotification, [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue, AVAudioSessionInterruptionOptionKey: command.hasPrefix("ended-no-resume") ? 0 : AVAudioSession.InterruptionOptions.shouldResume.rawValue])
                case "route": post(AVAudioSession.routeChangeNotification, [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
                case "background": NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
                case "foreground": NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
                case "reset": post(AVAudioSession.mediaServicesWereResetNotification)
                case "a11y-pause": performAccessibilityAction("Pause")
                case "a11y-mute": performAccessibilityAction("Mute")
                case "a11y-cc": performAccessibilityAction("Captions off")
                case "a11y-increment": progressElement()?.accessibilityIncrement()
                case "a11y-decrement": progressElement()?.accessibilityDecrement()
                default: break
                }
            }
            message = "CC and audio preferences survive swipes. Local synthetic content."
            try? await Task.sleep(for: .milliseconds(200))
        }
        #endif
    }
    @MainActor private func allViews() -> [UIView] {
        func descend(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descend) }
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).flatMap(descend)
    }
    @MainActor private func allElements() -> [UIAccessibilityElement] { allViews().flatMap { $0.accessibilityElements ?? [] }.compactMap { $0 as? UIAccessibilityElement } }
    @MainActor private func progressElement() -> UIAccessibilityElement? { allElements().first { $0.accessibilityIdentifier == "hm-playback-position" } }
    @MainActor private func performAccessibilityAction(_ name: String) {
        if let action = allElements().flatMap({ $0.accessibilityCustomActions ?? [] }).first(where: { $0.name == name }) { _ = action.actionHandler?(action) }
    }
    @MainActor private func accessibilityEvidence() -> [[String: Any]] {
        var values: [[String: Any]] = allElements().filter { $0.accessibilityIdentifier?.hasPrefix("hm-") == true }.map {
            ["id": $0.accessibilityIdentifier ?? "", "label": $0.accessibilityLabel ?? "", "value": $0.accessibilityValue ?? "", "frame": NSCoder.string(for: $0.accessibilityFrame), "actions": ($0.accessibilityCustomActions ?? []).map(\.name)]
        }
        for label in allViews().compactMap({ $0 as? UILabel }).filter({ $0.accessibilityIdentifier == "hm-caption-text" && !$0.isHidden }) {
            values.append(["id": "hm-caption-text", "text": label.text ?? "", "frame": NSCoder.string(for: label.convert(label.bounds, to: nil))])
        }
        return values
    }
}

private struct CaptionLabSafeChrome<Content: View>: View {
    @Environment(\.hmFeedSafeArea) private var safeArea
    @ViewBuilder let content: () -> Content
    var body: some View { content().padding(.top, safeArea.top).padding(.bottom, safeArea.bottom) }
}

#endif
