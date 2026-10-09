#if canImport(AVFAudio) && os(iOS)
import AVFAudio
import OSLog

/// Thin, opinionated audio session helper.
///
/// A feed player wants `.playback` so audio continues with the ringer off, and
/// `.mixWithOthers` is deliberately *not* set — a vertical feed is a foreground
/// experience that should duck other audio.
enum HMAudioSession {
    private static let logger = Logger(subsystem: "com.hotmic.player", category: "audio")

    /// Activates playback audio.
    static func activatePlayback() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            logger.error("audio session activate failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Deactivates playback audio.
    static func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            logger.error("audio session deactivate failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#else
/// Internal audio session helper.
enum HMAudioSession {
    /// Activates playback audio.
    static func activatePlayback() {}
    /// Deactivates playback audio.
    static func deactivate() {}
}
#endif
