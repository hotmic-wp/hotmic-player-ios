import SwiftUI
import UIKit

/// BR demo build. Shares the generic Sample's sources and TestSupport; only the entry point,
/// the home screen and the BR content live in this folder.
@main
struct BRPlayerDemoApp: App {
    @UIApplicationDelegateAdaptor(BRPlayerDemoAppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup {
            BRDemoRootView()
        }
    }
}

/// The generic Sample's Debug-only orientation hook; its file is excluded from this target.
final class BRPlayerDemoAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        #if DEBUG
        if DemoOptions().values["portrait-only"] == "1" { return .portrait }
        #endif
        return .allButUpsideDown
    }
}

/// The BR feed by default. Any `--hm-*` launch argument or `HM_*` variable routes to the generic
/// Sample root instead, so the shared UI tests and lab screens run unchanged against this build.
struct BRDemoRootView: View {
    private let options = DemoOptions()
    @ViewBuilder var body: some View {
        if options.values.isEmpty { BRFeedScreen() } else { DemoRootView() }
    }
}
