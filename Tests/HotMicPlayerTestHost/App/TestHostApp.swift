import UIKit

/// Empty UIKit host for the package's native tests. Xcode injects the
/// `HotMicPlayerTests` bundle (`TEST_HOST`) after `UIApplicationMain` launches this
/// app. It links no SDK and starts no media, network or customer services.
@main
final class TestHostAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        TestHostBootstrap.record("launch begin")
        return true
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        TestHostBootstrap.record("launch end", "state=\(application.applicationState.rawValue)")
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = TestHostSceneDelegate.self
        return configuration
    }
}

final class TestHostSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        TestHostBootstrap.record("scene connect begin")
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
        TestHostBootstrap.window = window
        TestHostBootstrap.record("window visible", "bounds=\(window.bounds.size) scale=\(window.traitCollection.displayScale) rootLoaded=\(window.rootViewController?.isViewLoaded == true)")
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        TestHostBootstrap.record("scene active")
    }
}

/// Launch receipts. Each phase is written once to stderr (with this process ID) and kept
/// for the tests' host check; there is no readiness flag, wait or retry.
@MainActor enum TestHostBootstrap {
    private(set) static var receipts: [String: TimeInterval] = [:]
    static weak var window: UIWindow?

    static func record(_ phase: String, _ detail: String = "") {
        guard receipts[phase] == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        receipts[phase] = now
        let line = "[test-host] \(now) \(Date().ISO8601Format()) pid=\(getpid()) \(phase)\(detail.isEmpty ? "" : " \(detail)")\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
