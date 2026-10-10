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
import AVFAudio
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
        let player = HMPlayer(configuration: configuration)
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
        player.handleAudioNotification(Notification(name: AVAudioSession.mediaServicesWereResetNotification))
        player.teardown()
        #expect(HMAudioSession.configurationCount == count)
        #expect(session.category == category && session.mode == mode)
    }
    @MainActor @Test("Native actions invoke core controls, update names and become inert while disabled")
    func nativeActions() {
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
#endif
