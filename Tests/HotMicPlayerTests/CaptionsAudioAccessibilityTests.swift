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
        try await diagnosticsLifetime()
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
        interruption(.began)
        #expect(!player.mediaProgressAllowed)
        interruption(.ended, shouldResume: false)
        #expect(player.mediaProgressAllowed)
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
        #expect(!player.mediaProgressAllowed)
        player.handleAudioNotification(Notification(name: UIApplication.didEnterBackgroundNotification))
        player.handleAudioNotification(Notification(name: UIApplication.didBecomeActiveNotification))
        #expect(player.wantsPlayback && !player.mediaProgressAllowed)
        player.isFeedVisible = true
        #expect(player.mediaProgressAllowed)
        interruption(.ended) // no matching began; preserve intent
        #expect(player.wantsPlayback)
        player.pause(); interruption(.began); interruption(.ended)
        #expect(!player.wantsPlayback)
        #expect(player.lastEvent == .audioSession(.interruptionEnded(shouldResume: true, resumed: false)))
        player.play()
        player.handleAudioNotification(Notification(name: AVAudioSession.routeChangeNotification, userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue]))
        #expect(!player.wantsPlayback)
        player.handleAudioNotification(Notification(name: UIApplication.didEnterBackgroundNotification))
        #expect(!player.mediaProgressAllowed)
        player.handleAudioNotification(Notification(name: UIApplication.didBecomeActiveNotification))
        #expect(!player.wantsPlayback && player.mediaProgressAllowed)
        #expect(player.lastEvent == .audioSession(.enteredForeground(resumed: false)))
        // The latest host play/navigation intent wins over the background snapshot.
        for navigate in [false, true] {
            player.pause()
            player.handleAudioNotification(Notification(name: UIApplication.didEnterBackgroundNotification))
            if navigate { await player.requestPlay(at: 0) } else { player.play() }
            #expect(player.wantsPlayback && !player.mediaProgressAllowed)
            player.handleAudioNotification(Notification(name: UIApplication.didBecomeActiveNotification))
            #expect(player.wantsPlayback && player.mediaProgressAllowed)
            #expect(player.lastEvent == .audioSession(.enteredForeground(resumed: true)))
            player.pause()
        }
        let oldNodes = player.pool.nodes
        player.captionsEnabled = true
        player.handleAudioNotification(Notification(name: AVAudioSession.mediaServicesWereResetNotification))
        #expect(!player.wantsPlayback && player.mediaProgressAllowed)
        #expect(Set(sink.detached) == Set(oldNodes.map(\.id)))
        #expect(zip(oldNodes, player.pool.nodes).allSatisfy { $0 !== $1 })
        #expect(player.pool.nodes.allSatisfy { $0.onBufferChanged != nil && $0.captions.onLanguagesChanged != nil })
        player.configuration.allowsBackgroundAudio = true
        #expect(player.pool.nodes.allSatisfy { $0.player.audiovisualBackgroundPlaybackPolicy == .continuesIfPossible })
        let adNode = HMPlayerNode(id: "ad-policy", configuration: player.configuration)
        #expect(adNode.player.audiovisualBackgroundPlaybackPolicy == .continuesIfPossible)
        adNode.release()
        // Reset resumes this visit's position even when ordinary revisits restart.
        let url = try await PlayerNativeReviewTests().videoFixture(rotated: false, duration: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        var recoveryConfiguration = HMPlayerConfiguration(managesAudioSession: false)
        recoveryConfiguration.prefetch = .off; recoveryConfiguration.restoresPlaybackPosition = false
        let recovery = HMPlayer(configuration: recoveryConfiguration)
        defer { recovery.teardown() }
        recovery.replaceAll([HMMediaItem(id: "reset-position", url: url, format: .mp4), HMMediaItem(id: "other", url: url, format: .mp4)])
        await recovery.requestPlay(at: 0)
        let ready = Date().addingTimeInterval(3)
        while recovery.snapshot.duration < 2, Date() < ready { await Task.yield() }
        recovery.pause(); recovery.seek(to: 1)
        while abs((recovery.currentNode?.player.currentTime().seconds ?? 0) - 1) > 0.1, Date() < ready { await Task.yield() }
        #expect(abs(recovery.snapshot.currentTime - 1) < 0.1)
        recovery.handleAudioNotification(Notification(name: AVAudioSession.mediaServicesWereResetNotification))
        let restored = Date().addingTimeInterval(3)
        while abs((recovery.currentNode?.player.currentTime().seconds ?? 0) - 1) > 0.1, Date() < restored { await Task.yield() }
        #expect(abs((recovery.currentNode?.player.currentTime().seconds ?? 0) - 1) < 0.1)
        while recovery.snapshot.currentTime < 0.9, Date() < restored { await Task.yield() }
        #expect(recovery.snapshot.currentTime >= 0.9)
        #expect(!recovery.wantsPlayback && recovery.mediaProgressAllowed)
        // A blocked reset has no current node until eligibility returns. Preparing
        // that current is independent of autoplay intent on both recovery paths.
        for background in [false, true] {
            recovery.handleAudioNotification(Notification(name: background ? UIApplication.didEnterBackgroundNotification : AVAudioSession.interruptionNotification,
                userInfo: background ? nil : [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]))
            recovery.handleAudioNotification(Notification(name: AVAudioSession.mediaServicesWereResetNotification))
            #expect(recovery.currentNode == nil && !recovery.mediaProgressAllowed)
            recovery.handleAudioNotification(Notification(name: background ? UIApplication.didBecomeActiveNotification : AVAudioSession.interruptionNotification,
                userInfo: background ? nil : [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue, AVAudioSessionInterruptionOptionKey: 0]))
            let rebuilt = Date().addingTimeInterval(3)
            while recovery.snapshot.currentTime < 0.9, Date() < rebuilt { await Task.yield() }
            #expect(recovery.currentNode != nil && !recovery.wantsPlayback && recovery.mediaProgressAllowed)
            #expect(abs((recovery.currentNode?.player.currentTime().seconds ?? 0) - 1) < 0.1)
        }
        // A queued hidden reset must not leak to a different visit, even on a swipe back.
        recovery.isFeedVisible = false
        recovery.handleAudioNotification(Notification(name: AVAudioSession.mediaServicesWereResetNotification))
        recovery.next(); recovery.previous(); recovery.pause(); recovery.isFeedVisible = true
        let restarted = Date().addingTimeInterval(2)
        while recovery.currentNode?.player.currentItem?.status != .readyToPlay, Date() < restarted { await Task.yield() }
        #expect((recovery.currentNode?.player.currentTime().seconds ?? 0) < 0.1)
        #expect(!recovery.configuration.restoresPlaybackPosition)
        player.teardown()
        #expect(HMAudioSession.configurationCount == count)
        #expect(session.category == category && session.mode == mode)
        var managedConfiguration = configuration; managedConfiguration.managesAudioSession = true
        let managed = HMPlayer(configuration: managedConfiguration)
        defer { managed.teardown() }
        managed.replaceAll([.reference("test", id: "latest-intent")]); managed.pause()
        managed.handleAudioNotification(Notification(name: UIApplication.didEnterBackgroundNotification))
        let beforePlay = HMAudioSession.configurationCount
        managed.play()
        #expect(HMAudioSession.configurationCount == beforePlay)
        managed.handleAudioNotification(Notification(name: UIApplication.didBecomeActiveNotification))
        #expect(managed.lastEvent == .audioSession(.enteredForeground(resumed: true)))
        #expect(HMAudioSession.configurationCount == beforePlay + 1)

    }
    @MainActor private func diagnosticsLifetime() async throws {
        let options = HMPlayerDiagnosticsConfiguration(baseURL: URL(string: "http://127.0.0.1:9")!, appKey: "synthetic", samplingPercent: 100)
        let legacyFactory: @MainActor (HMPlayerConfiguration, (any HMItemResolver)?, (any HMInteractionSource)?, HMAnalyticsHub?) -> HMPlayer = HMPlayer.init(configuration:resolver:interactions:analytics:)
        let legacy = legacyFactory(.default, nil, nil, nil)
        #expect(legacy.diagnosticsRecorder == nil); legacy.teardown()
        let explicit = HMPlayer(diagnostics: options)
        #expect(explicit.diagnosticsRecorder != nil); explicit.teardown()
        let player = HMPlayer()
        #expect(player.diagnosticsRecorder == nil)
        let count = player.preparedItemCount
        player.setDiagnostics(.init(baseURL: options.baseURL, appKey: options.appKey, samplingPercent: 0))
        #expect(player.diagnosticsRecorder == nil)
        player.setDiagnostics(options)
        weak var owned = player.diagnosticsRecorder
        #expect(owned != nil && player.preparedItemCount == count)
        player.isFeedVisible = false; #expect(owned?.aggregate == nil)
        player.setDiagnostics(options); owned = player.diagnosticsRecorder
        #expect(owned?.aggregate == nil) // constructed suspended, no transient window
        player.isFeedVisible = true; #expect(owned?.aggregate != nil)
        player.handleAudioNotification(Notification(name: UIApplication.didEnterBackgroundNotification))
        #expect(owned?.aggregate == nil)
        player.handleAudioNotification(Notification(name: UIApplication.didBecomeActiveNotification))
        #expect(owned?.aggregate != nil)
        player.setDiagnostics(nil); #expect(owned == nil)
        player.setDiagnostics(options); weak var terminal = player.diagnosticsRecorder
        player.teardown(); #expect(terminal == nil)
        player.setDiagnostics(options); #expect(player.diagnosticsRecorder == nil)

        let recorder = HMDiagnosticsRecorder(options: options, configuration: .default, lastAttempt: -.infinity, eligible: { false })
        defer { recorder.suspend() }
        let began = recorder.began
        recorder.record(.attempt, at: began + 59.9)
        recorder.record(.attempt, at: began + 60)
        recorder.record(.firstFrame(149), at: began + 59)
        recorder.record(.moving(251), at: began + 59)
        recorder.record(.stall(500), at: began + 59)
        #expect(recorder.aggregate?.playback.attempted == 1)
        #expect(recorder.aggregate?.startup_buckets[1] == 1 && recorder.aggregate?.moving_start_buckets[3] == 1)
        #expect(recorder.aggregate?.stalls.total_duration_ms == 500)
        recorder.close(at: began + 60.2)
        #expect(recorder.aggregate?.playback.attempted == 0 && recorder.lastAttempt == -.infinity)
        let second = recorder.began
        // Decreasing grid lateness is an early wake for the new one-shot window.
        recorder.record(.attempt, at: second + 59.7)
        recorder.close(at: began + 120.05)
        #expect(recorder.began == second && recorder.aggregate?.playback.attempted == 1)
        recorder.close(at: second + 60.05)
        #expect(recorder.began == second + 60.05 && recorder.aggregate?.playback.attempted == 0)
        let overflowBegan = recorder.began
        for _ in 0...10_000 { recorder.record(.attempt, at: overflowBegan + 1) }
        #expect(recorder.aggregate?.invalid == true)
        recorder.close(at: overflowBegan + 120)
        #expect(recorder.aggregate?.playback.attempted == 0)
        recorder.record(.stall(.infinity), at: recorder.began + 1)
        #expect(recorder.aggregate?.invalid == true)
        recorder.configure(.highQuality); #expect(recorder.aggregate?.config.startup_bps == 0)
        recorder.discardForPressure(); #expect(recorder.aggregate?.invalid == true)
        recorder.suspend(); #expect(recorder.aggregate == nil)

        let alignedCadence = HMDiagnosticsCadence()
        let aligned = HMDiagnosticsRecorder(options: options, configuration: .default, lastAttempt: -.infinity,
            cadence: alignedCadence, eligible: { false })
        let alignedBegan = aligned.began
        #expect(alignedCadence.reserve(at: alignedBegan + 0.25))
        aligned.record(.attempt, at: alignedBegan + 59)
        aligned.close(at: alignedBegan + 60.05)
        #expect(aligned.began == alignedBegan && aligned.aggregate?.playback.attempted == 1)
        let alignedDeadline = alignedCadence.lastAttempt + 60
        aligned.close(at: alignedDeadline)
        #expect(aligned.began == alignedDeadline && aligned.aggregate?.playback.attempted == 0)
        aligned.suspend()

        let measured = HMDiagnosticsRecorder(options: options, configuration: .default, lastAttempt: -.infinity, eligible: { false })
        let at = measured.began + 1
        let disabled: HMDiagnosticsRecorder? = nil
        let offStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<5000 { disabled?.record(.firstFrame(149), at: at) }
        let off = ProcessInfo.processInfo.systemUptime - offStart
        let onStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<5000 { measured.record(.firstFrame(149), at: at) }
        let on = ProcessInfo.processInfo.systemUptime - onStart
        #expect(measured.aggregate?.playback.first_frames == 5000)
        print("Diagnostics capture simulator smoke: 5000 identical observations off=\(off)s on=\(on)s; fixed eight buckets, no per-event tasks")
        measured.suspend()

        let spacing = HMDiagnosticsCadence()
        // Fixed quarter-second endpoints keep the 60 s boundary binary-exact.
        #expect(spacing.reserve(at: 60.25))
        #expect(!spacing.reserve(at: 120.05)) // 59.8 s is not an admissible attempt.
        #expect(spacing.reserve(at: 120.25))
        let cadence = HMDiagnosticsCadence()
        #expect(cadence.reserve(at: 60)); #expect(!cadence.reserve(at: 119.999)); #expect(cadence.reserve(at: 120))
        let snapshot = HMDiagnosticsAggregate(config: try #require(HMDiagnosticsConfig(.default)), rate: 1)
        let serialized = try #require(JSONSerialization.jsonObject(with: try JSONEncoder().encode(snapshot)) as? [String: Any])
        #expect(serialized["sdk_version"] as? String == "1.0.0")
        #expect(serialized["schema_version"] as? Int == 1)
        let url = URL(string: "https://diagnostics.unit.test/v2/player/diagnostics")!
        DiagnosticsURLProtocol.reset(202)
        let oversized = HMDiagnosticsTransport(endpoint: url, appKey: "synthetic", protocolClasses: [DiagnosticsURLProtocol.self])
        var excessive = snapshot
        excessive.startup_buckets = [Int](repeating: 10_000, count: 2000)
        #expect(oversized.submit(excessive))
        for _ in 0..<100 where oversized.busy { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!oversized.busy && DiagnosticsURLProtocol.counts.0 == 0)
        oversized.cancel()
        for mode in [202, 503, 429, 0] {
            DiagnosticsURLProtocol.reset(mode)
            let transport = HMDiagnosticsTransport(endpoint: url, appKey: "synthetic", protocolClasses: [DiagnosticsURLProtocol.self])
            #expect(transport.submit(snapshot))
            for _ in 0..<100 where transport.busy { try await Task.sleep(for: .milliseconds(5)) }
            #expect(!transport.busy)
            try await Task.sleep(for: .milliseconds(30))
            #expect(DiagnosticsURLProtocol.counts.0 == 1)
            transport.cancel()
        }
        let headersOnly = HMDiagnosticsTransport(endpoint: url, appKey: "synthetic")
        let unstartedSession = URLSession(configuration: .ephemeral)
        let unstartedTask = unstartedSession.dataTask(with: url)
        let largeResponse = HTTPURLResponse(url: url, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "1073741824"])!
        headersOnly.urlSession(unstartedSession, dataTask: unstartedTask, didReceive: largeResponse) { disposition in
            #expect(disposition == .cancel)
        }
        unstartedSession.invalidateAndCancel(); headersOnly.cancel()
        DiagnosticsURLProtocol.reset(1)
        let timedOut = HMDiagnosticsTransport(endpoint: url, appKey: "synthetic", protocolClasses: [DiagnosticsURLProtocol.self])
        #expect(timedOut.submit(snapshot))
        for _ in 0..<120 where timedOut.busy { try await Task.sleep(for: .milliseconds(25)) }
        #expect(!timedOut.busy && DiagnosticsURLProtocol.counts.0 == 1)
        timedOut.cancel()
        DiagnosticsURLProtocol.reset(1)
        let busy = HMDiagnosticsTransport(endpoint: url, appKey: "synthetic", protocolClasses: [DiagnosticsURLProtocol.self])
        #expect(busy.submit(snapshot)); #expect(!busy.submit(snapshot))
        for _ in 0..<100 where DiagnosticsURLProtocol.counts.0 == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(DiagnosticsURLProtocol.counts.0 == 1)
        busy.cancel(); #expect(!busy.submit(snapshot))
        try await Task.sleep(for: .milliseconds(30))
        #expect(DiagnosticsURLProtocol.counts.0 == 1)
        // Publication/cancel races cannot retain a transport through its URLSession delegate.
        for _ in 0..<20 {
            var transport: HMDiagnosticsTransport? = HMDiagnosticsTransport(endpoint: url, appKey: "synthetic", protocolClasses: [DiagnosticsURLProtocol.self])
            weak var weakTransport = transport
            _ = transport?.submit(snapshot); transport?.cancel(); transport = nil
            for _ in 0..<100 where weakTransport != nil { try await Task.sleep(for: .milliseconds(2)) }
            #expect(weakTransport == nil)
        }

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
    @MainActor @Test("Only declared legible tracks count as caption languages; the undeclared closed-caption placeholder never does")
    func declaredCaptionTracks() {
        // A multivariant playlist without CLOSED-CAPTIONS makes AVFoundation offer one closed-caption option with
        // no language, no locale and the display name "CC" (seen on an iPhone); CLOSED-CAPTIONS=NONE removes it.
        let placeholder = HMLegibleOption(mediaType: .closedCaption, languageTag: nil, localeIdentifier: nil, forcedOnly: false)
        #expect(!placeholder.isCaptionTrack)
        let declared = HMLegibleOption(mediaType: .closedCaption, languageTag: "en", localeIdentifier: "en", forcedOnly: false)
        #expect(declared.isCaptionTrack && declared.language(index: 3) == "en")
        let localeOnly = HMLegibleOption(mediaType: .closedCaption, languageTag: nil, localeIdentifier: "es_MX", forcedOnly: false)
        #expect(localeOnly.isCaptionTrack && localeOnly.language(index: 0) == "es_MX")
        let untaggedSubtitles = HMLegibleOption(mediaType: .subtitle, languageTag: nil, localeIdentifier: nil, forcedOnly: false)
        #expect(untaggedSubtitles.isCaptionTrack && untaggedSubtitles.language(index: 2) == "und-2")
        let forced = HMLegibleOption(mediaType: .subtitle, languageTag: "fr", localeIdentifier: "fr", forcedOnly: true)
        #expect(!forced.isCaptionTrack)
        #expect(HMCaptionController.captionLanguages(sidecars: [], options: [placeholder]).isEmpty)
        #expect(HMCaptionController.captionLanguages(sidecars: ["en"], options: [placeholder]) == ["en"])
        // Names keep the option's position in the group, so a later selection finds the same option.
        #expect(HMCaptionController.captionLanguages(sidecars: [], options: [placeholder, untaggedSubtitles, declared]) == ["en", "und-1"])
        #expect(HMCaptionController.captionLanguages(sidecars: ["en", "de"], options: [declared, forced]) == ["de", "en"])
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

// Controlled transport outcomes extend the existing lifecycle cohort; no live key/API.
private final class DiagnosticsURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var attempts = 0
    private static var stops = 0
    private static var mode = 202
    static func reset(_ value: Int) { lock.lock(); attempts = 0; stops = 0; mode = value; lock.unlock() }
    static var counts: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (attempts, stops) }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "diagnostics.unit.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.attempts += 1; let status = Self.mode; Self.lock.unlock()
        if status == 0 { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        if status == 1 { return } // Hold the slot for busy/cancel coverage.
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "1", "Retry-After": "1"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Custom URLProtocol needs a first byte to surface headers to Foundation.
        // The real local HTTP cohort separately verifies streaming cancellation.
        client?.urlProtocol(self, didLoad: Data([0]))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.lock.lock(); Self.stops += 1; Self.lock.unlock() }
}
