import SwiftUI
import UIKit

@main
struct HotMicPlayerDemoApp: App {
    @UIApplicationDelegateAdaptor(HorizontalLabAppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup {
            DemoRootView()
        }
    }
}

/// Debug-only host restrictions exercise the SDK without changing target orientation metadata.
final class HorizontalLabAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        #if DEBUG
        if DemoOptions().values["portrait-only"] == "1" { return .portrait }
        #endif
        return .allButUpsideDown
    }
}
