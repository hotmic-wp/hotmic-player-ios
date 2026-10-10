#if canImport(UIKit) && !os(watchOS)
import Foundation
import MediaAccessibility

/// Callbacks use an opaque registry key, never a pointer into an observer's lifetime.
private final class HMCaptionCallbackRegistry: @unchecked Sendable {
    static let shared = HMCaptionCallbackRegistry()
    private let lock = NSLock()
    private var next: UInt = 0
    private var callbacks: [UInt: @MainActor () -> Void] = [:]
    func add(_ callback: @escaping @MainActor () -> Void) -> UInt {
        lock.lock(); defer { lock.unlock() }
        next += 1; callbacks[next] = callback; return next
    }
    func remove(_ key: UInt) {
        lock.lock(); defer { lock.unlock() }; callbacks[key] = nil
    }
    @MainActor func invoke(_ key: UInt) {
        lock.lock(); let callback = callbacks[key]; lock.unlock()
        callback?()
    }
}

/// MediaAccessibility publishes a CF notification, rather than a NotificationCenter notification.
@MainActor final class HMCaptionSettingsObserver {
    private let key: UInt
    init(changed: @escaping @MainActor () -> Void) {
        key = HMCaptionCallbackRegistry.shared.add(changed)
        CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), UnsafeRawPointer(bitPattern: key), { _, observer, _, _, _ in
            guard let observer else { return }
            let key = UInt(bitPattern: observer)
            Task { @MainActor in HMCaptionCallbackRegistry.shared.invoke(key) }
        }, kMACaptionAppearanceSettingsChangedNotification, nil, .deliverImmediately)
    }
    func cancel() {
        HMCaptionCallbackRegistry.shared.remove(key)
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetLocalCenter(), UnsafeRawPointer(bitPattern: key), CFNotificationName(kMACaptionAppearanceSettingsChangedNotification), nil)
    }
    deinit {
        HMCaptionCallbackRegistry.shared.remove(key)
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetLocalCenter(), UnsafeRawPointer(bitPattern: key), CFNotificationName(kMACaptionAppearanceSettingsChangedNotification), nil)
    }
}
#endif
