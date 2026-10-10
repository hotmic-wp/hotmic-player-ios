import Foundation
import Testing
@_spi(Benchmark) @testable import HotMicPlayer

@Suite("Captions, audio lifecycle and core accessibility", .serialized)
struct CaptionsAudioAccessibilityTests {
    @Test("VTT parses cue IDs, timestamps, multiline tags and entities; rejects malformed intervals")
    func webVTT() {
        let cues = HMWebVTT.parse("\u{feff}WEBVTT\r\n\r\nintro\r\n00:01.000 --> 00:03.500 align:start\r\n<v Coach>Hello &amp; <b>welcome</b>\r\nsecond line\r\n\r\nNOTE ignored\r\nanything\r\n\r\n01:02:03.000 --> 01:02:04.000\r\nLate cue\r\n\r\n00:08.000 --> 00:04.000\r\nBackwards\r\n\r\n00:99.000 --> 00:100.000\r\nInvalid")
        #expect(cues == [HMCaptionCue(start: 1, end: 3.5, text: "Hello & welcome\nsecond line"), HMCaptionCue(start: 3723, end: 3724, text: "Late cue")])
        #expect(HMWebVTT.parse("00:01.000 --> 00:02.000\nMissing header").isEmpty)
        let separated = HMWebVTT.parse("WEBVTT\n \t\nNOTEWORTHY\n00:00.000 --> 00:01.000\n&#65; &#x1F44B; &quot; &lrm;&rlm;\n \t\n00:01.000 --> 00:02.000\nSecond\n\nNOTE\tcomment\n00:02.000 --> 00:03.000\nIgnored")
        #expect(separated.map(\.text) == ["A 👋 \" \u{200e}\u{200f}", "Second"])
    }
    @Test("Sidecars survive reference resolution and ID changes without changing playback identity")
    func sidecarIdentity() {
        let url = URL(string: "https://example.invalid/en.vtt")!
        let original = HMMediaItem(id: "one", source: .reference(namespace: "host", id: "1"), captionSources: ["en": url])
        let resolved = original.resolved(HMResolvedItem(url: URL(string: "https://example.invalid/clip.mp4")!, format: .mp4))
        #expect(resolved.captionSources == ["en": url])
        #expect(resolved.identified("new").captionSources == resolved.captionSources)
        let without = HMMediaItem(id: "one", source: original.source)
        #expect(original != without)
        #expect(original.hasSameMedia(as: without))
    }
    @Test("Shared accessibility step clamps VOD and live seeks and rejects invalid timing")
    func seekPolicy() {
        #expect(HMAccessibility.seekStep == 10)
        #expect(HMAccessibility.seekTarget(position: 4, start: 0, duration: 12, increment: true) == 12)
        #expect(HMAccessibility.seekTarget(position: 4, start: 0, duration: 12, increment: false) == 0)
        #expect(HMAccessibility.seekTarget(position: 104, start: 100, duration: 20, increment: false) == 100)
        #expect(HMAccessibility.seekTarget(position: 114, start: 100, duration: 20, increment: true) == 120)
        #expect(HMAccessibility.seekTarget(position: .nan, start: .nan, duration: .infinity, increment: true) == 0)
    }
}

#if os(iOS)
import AVFoundation
import MediaAccessibility
import UIKit

extension CaptionsAudioAccessibilityTests {
    @MainActor @Test("Host-managed audio stays configured by its host; paused, unmatched and route notifications cannot resume")
    func audioObservation() async throws {
        let session = AVAudioSession.sharedInstance()
        let originalCategory = session.category, originalMode = session.mode
        try session.setCategory(.ambient, mode: .default)
        defer { try? session.setCategory(originalCategory, mode: originalMode) }
        let category = session.category, mode = session.mode
        var configuration = HMPlayerConfiguration()
        configuration.managesAudioSession = false
        configuration.startsMuted = true; configuration.loops = false
        let sink = ResetAttachmentSink()
        let player = HMPlayer(configuration: configuration, analytics: HMAnalyticsHub(sinks: [sink]))
        defer { player.teardown() }
        #expect(player.isMuted && !player.configuration.loops)
        player.replaceAll([.reference("test", id: "owned-session")])
        await player.requestPlay(at: 0)
        player.isFeedVisible = false; player.isFeedVisible = true
        let count = HMAudioSession.configurationCount
        let idle = HMPlayer()
        idle.handleAudioNotification(Notification(name: AVAudioSession.mediaServicesWereResetNotification))
        idle.teardown()
        #expect(HMAudioSession.configurationCount == count)
        #expect(session.category == category && session.mode == mode)
        func interruption(_ type: AVAudioSession.InterruptionType, shouldResume: Bool = true) {
            player.handleAudioNotification(Notification(name: AVAudioSession.interruptionNotification, userInfo: [
                AVAudioSessionInterruptionTypeKey: type.rawValue,
                AVAudioSessionInterruptionOptionKey: shouldResume ? AVAudioSession.InterruptionOptions.shouldResume.rawValue : 0]))
        }
        player.play()
        // No rate exists for an unresolved item; lifecycle recovery must keep the user's intent.
        interruption(.began); interruption(.ended)
        #expect(player.wantsPlayback)
        interruption(.began); interruption(.ended, shouldResume: false)
        #expect(!player.wantsPlayback)
        player.play(); interruption(.began)
        player.play() // recover without an ended notification
        #expect(player.wantsPlayback)
        player.handleAudioNotification(Notification(name: UIApplication.didBecomeActiveNotification))
        #expect(player.lastEvent == .audioSession(.enteredForeground(resumed: true)))
        interruption(.began)
        await player.requestPlay(at: 0)
        #expect(player.wantsPlayback)
        interruption(.began)
        player.handleAudioNotification(Notification(name: UIApplication.didBecomeActiveNotification))
        #expect(player.wantsPlayback)
        player.handleAudioNotification(Notification(name: AVAudioSession.interruptionNotification, userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
            AVAudioSessionInterruptionReasonKey: AVAudioSession.InterruptionReason.appWasSuspended.rawValue]))
        #expect(player.lastEvent != .audioSession(.interruptionBegan))
        player.handleAudioNotification(Notification(name: AVAudioSession.interruptionNotification, userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
            AVAudioSessionInterruptionWasSuspendedKey: true]))
        #expect(player.lastEvent != .audioSession(.interruptionBegan))
        player.isFeedVisible = false
        player.handleAudioNotification(Notification(name: UIApplication.didEnterBackgroundNotification))
        player.handleAudioNotification(Notification(name: UIApplication.didBecomeActiveNotification))
        #expect(player.wantsPlayback)
        player.isFeedVisible = true
        interruption(.ended) // no matching began; preserve intent
        #expect(player.wantsPlayback)
        player.pause(); interruption(.began); interruption(.ended)
        #expect(!player.wantsPlayback)
        #expect(player.lastEvent == .audioSession(.interruptionEnded(shouldResume: true, resumed: false)))
        player.play()
        player.handleAudioNotification(Notification(name: AVAudioSession.routeChangeNotification, userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue]))
        #expect(!player.wantsPlayback)
        player.handleAudioNotification(Notification(name: UIApplication.didEnterBackgroundNotification))
        player.handleAudioNotification(Notification(name: UIApplication.didBecomeActiveNotification))
        #expect(!player.wantsPlayback)
        let oldNodes = player.pool.nodes
        player.captionsEnabled = true
        player.handleAudioNotification(Notification(name: AVAudioSession.mediaServicesWereResetNotification))
        #expect(Set(sink.detached) == Set(oldNodes.map(\.id)))
        #expect(zip(oldNodes, player.pool.nodes).allSatisfy { $0 !== $1 })
        #expect(player.pool.nodes.allSatisfy { $0.onBufferChanged != nil && $0.captions.onLanguagesChanged != nil })
        player.configuration.allowsBackgroundAudio = true
        #expect(player.pool.nodes.allSatisfy { $0.player.audiovisualBackgroundPlaybackPolicy == .continuesIfPossible })
        let adNode = HMPlayerNode(id: "ad-policy", configuration: player.configuration)
        #expect(adNode.player.audiovisualBackgroundPlaybackPolicy == .continuesIfPossible)
        adNode.release()
        player.teardown()
        #expect(HMAudioSession.configurationCount == count)
        #expect(session.category == category && session.mode == mode)
    }
    @MainActor @Test("Native actions invoke core controls, update names and become inert while disabled")
    func nativeActions() {
        #expect(HMVideoAccessibility.position(2, duration: 12) == "2 of 12 seconds")
        let view = HMVideoGestureView()
        var playCount = 0, muteCount = 0, captionCount = 0
        view.toggle = { playCount += 1 }; view.mute = { muteCount += 1 }; view.caption = { captionCount += 1 }
        view.updateActions(wantsPlayback: true, muted: false, captions: false, hasCaptions: true)
        let actions = view.videoElement.accessibilityCustomActions ?? []
        #expect(actions.map(\.name) == ["Pause", "Mute", "Captions on"])
        for action in actions { #expect(action.actionHandler?(action) == true) }
        #expect(playCount == 1 && muteCount == 1 && captionCount == 1)
        view.updateActions(wantsPlayback: false, muted: true, captions: true, hasCaptions: true)
        #expect(view.videoElement.accessibilityCustomActions?.map(\.name) == ["Play", "Unmute", "Captions off"])
        view.progressElement.position = 104; view.progressElement.start = 100; view.progressElement.duration = 30
        var target: Double?
        view.progressElement.seek = { target = $0 }
        view.progressElement.accessibilityIncrement(); #expect(target == 114)
        view.enabled = false
        view.progressElement.accessibilityDecrement(); #expect(target == 114)
        for action in actions { #expect(action.actionHandler?(action) == false) }
        #expect(playCount == 1 && muteCount == 1 && captionCount == 1)
    }
    @Test("Selected captions bypass saturated prefetch and failed tracks are not repeatedly fetched")
    func captionDownloadAdmission() async {
        let probe = CaptionDownloadProbe()
        let cache = HMCaptionCache(load: { await probe.load($0) })
        let tasks = (0..<8).map { index in
            Task { await cache.cues(for: URL(string: "https://example.invalid/warm-\(index)")!, prefetch: true) }
        }
        for _ in 0..<100 {
            if await probe.warmCount == 8 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await probe.warmCount == 8)
        let selected = await cache.cues(for: URL(string: "https://example.invalid/selected")!)
        #expect(selected.first?.text == "Selected")
        let missing = URL(string: "https://example.invalid/missing")!
        _ = await cache.cues(for: missing); _ = await cache.cues(for: missing)
        #expect(await probe.missingCount == 1)
        await probe.release()
        for task in tasks { _ = await task.value }
    }
    @MainActor @Test("Warm caption selection and cancelled settings callbacks survive native object lifetimes")
    func captionLifetime() async throws {
        #expect(HMCaptionController.matchLanguage(in: ["fr", "en-US"], preferences: ["en-GB"]) == "en-US")
        #expect(HMCaptionController.matchLanguage(in: ["fr"], preferences: ["en"]) == nil)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".vtt")
        try Data("WEBVTT\n\n00:00.000 --> 00:10.000\nWarm cue".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let player = HMPlayer()
        defer { player.teardown() }
        player.selectCaption("en")
        let media = HMMediaItem(id: "warm", url: file.deletingPathExtension().appendingPathExtension("mp4"), captionSources: ["en": file])
        let warm = player.pool.node(for: media, protecting: [])
        for _ in 0..<100 {
            if !warm.captions.cues.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(!warm.isActive)
        #expect(warm.captions.text(at: 1) == "Warm cue")
        var calls = 0
        var observer: HMCaptionSettingsObserver? = HMCaptionSettingsObserver { calls += 1 }
        CFNotificationCenterPostNotification(CFNotificationCenterGetLocalCenter(), CFNotificationName(kMACaptionAppearanceSettingsChangedNotification), nil, nil, true)
        observer?.cancel(); observer = nil
        await Task.yield()
        #expect(calls == 0)
    }
    @MainActor @Test("Caption overlay fits complete text outside rail and metadata, and hides if fully occluded")
    func placement() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        let regions = [CGRect(x: 0, y: 640, width: 400, height: 160), CGRect(x: 320, y: 250, width: 80, height: 390)]
        let view = HMCaptionOverlayView(frame: bounds)
        view.update(text: "A caption over video", videoFrame: bounds, safeArea: HMVideoInsets(top: 60, bottom: 34), insets: HMVideoInsets(bottom: 90), regions: regions)
        view.layoutIfNeeded()
        #expect(!view.label.isHidden)
        #expect(HMOverlayRegions.isFree(view.label.frame, videoFrame: bounds, in: bounds, safeArea: HMVideoInsets(top: 60, bottom: 34), contentInsets: HMVideoInsets(bottom: 90), excluding: regions))
        view.update(text: "A caption over video", videoFrame: bounds, safeArea: .zero, insets: .zero, regions: [bounds])
        view.layoutIfNeeded(); #expect(view.label.isHidden)
    }
}
@MainActor private final class ResetAttachmentSink: HMAnalyticsSink {
    let sinkName = "reset-attachments"
    var detached: [String] = []
    func handle(_ event: HMPlaybackEvent, item: HMMediaItem) {}
    func detach(playerKey: String) { detached.append(playerKey) }
}
private actor CaptionDownloadProbe {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var warmCount = 0
    private(set) var missingCount = 0
    func load(_ url: URL) async -> [HMCaptionCue] {
        if url.lastPathComponent.hasPrefix("warm-") {
            warmCount += 1
            await withCheckedContinuation { waiters.append($0) }
            return []
        }
        if url.lastPathComponent == "missing" { missingCount += 1; return [] }
        return [HMCaptionCue(start: 0, end: 1, text: "Selected")]
    }
    func release() { for waiter in waiters { waiter.resume() }; waiters.removeAll() }
}
#endif
