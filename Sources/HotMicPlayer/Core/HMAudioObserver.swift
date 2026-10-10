#if os(iOS)
import AVFAudio
import UIKit

@MainActor final class HMAudioObserver {
    private var tokens: [NSObjectProtocol] = []
    init(handler: @escaping (Notification) -> Void) {
        let names: [Notification.Name] = [AVAudioSession.interruptionNotification,
            AVAudioSession.routeChangeNotification, AVAudioSession.mediaServicesWereResetNotification,
            UIApplication.didEnterBackgroundNotification, UIApplication.didBecomeActiveNotification]
        tokens = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { handler(note) }
            }
        }
    }
    func cancel() {
        tokens.forEach(NotificationCenter.default.removeObserver); tokens = []
    }
    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}
#endif
