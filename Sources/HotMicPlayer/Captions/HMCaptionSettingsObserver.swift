#if canImport(UIKit) && !os(watchOS)
import Foundation
import MediaAccessibility

/// MediaAccessibility publishes a CF notification, rather than a NotificationCenter notification.
@MainActor final class HMCaptionSettingsObserver {
    private let changed: () -> Void
    init(changed: @escaping () -> Void) {
        self.changed = changed
        CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), Unmanaged.passUnretained(self).toOpaque(), { _, observer, _, _, _ in
            guard let observer else { return }
            let owner = Unmanaged<HMCaptionSettingsObserver>.fromOpaque(observer).takeUnretainedValue()
            Task { @MainActor [weak owner] in owner?.changed() }
        }, kMACaptionAppearanceSettingsChangedNotification, nil, .deliverImmediately)
    }
    func cancel() {
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetLocalCenter(), Unmanaged.passUnretained(self).toOpaque(), CFNotificationName(kMACaptionAppearanceSettingsChangedNotification), nil)
    }
    deinit {
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetLocalCenter(), Unmanaged.passUnretained(self).toOpaque(), CFNotificationName(kMACaptionAppearanceSettingsChangedNotification), nil)
    }
}
#endif
