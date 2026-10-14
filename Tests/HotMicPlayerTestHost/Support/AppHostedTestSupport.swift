import Foundation
import Testing
import UIKit
@testable import HotMicPlayerTestHost

/// SwiftPM generates `Bundle.module` for the package test target. This app-hosted
/// bundle copies the same `Fixtures` folder into itself instead.
extension Foundation.Bundle {
    static let module = Bundle(for: AppHostedTestBundleToken.self)
}

private final class AppHostedTestBundleToken {}

@MainActor enum AppHostedTestEnvironment {
    /// Checks, without waiting, that this test runs in the launched UIKit test host
    /// (not the xctest agent) and that the host's window scene is connected.
    static func requireLaunchedHost() throws {
        try #require(pthread_main_np() == 1)
        let tests = Bundle(for: AppHostedTestBundleToken.self)
        let host = Bundle.main
        try #require(host.bundleIdentifier == "com.hotmic.player.tests.host")
        try #require(tests.bundleURL.resolvingSymlinksInPath().path.hasPrefix(host.bundleURL.resolvingSymlinksInPath().path + "/"))
        try #require(UIApplication.shared.delegate is TestHostAppDelegate)
        let launched = try #require(TestHostBootstrap.receipts["launch end"])
        let window = try #require(TestHostBootstrap.window)
        let scene = try #require(window.windowScene)
        try #require(UIApplication.shared.connectedScenes.contains(scene))
        try #require(!window.isHidden && !window.bounds.isEmpty && window.traitCollection.displayScale > 0)
        let root = try #require(window.rootViewController)
        try #require(root.isViewLoaded && root.view.window === window)
        nativeTestPhase("app host verified process=\(ProcessInfo.processInfo.processName) pid=\(getpid()) host=\(host.bundleIdentifier ?? "nil") tests=\(tests.bundleURL.lastPathComponent) launchEnd=\(launched) windowVisible=\(TestHostBootstrap.receipts["window visible"] ?? -1) sceneState=\(scene.activationState.rawValue) key=\(window.isKeyWindow) bounds=\(window.bounds.size) scale=\(window.traitCollection.displayScale)")
    }
}
