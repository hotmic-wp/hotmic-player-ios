import XCTest

/// Public native behavior acceptance; no benchmark grid or private dependencies.
final class PlayerRegressionUITests: XCTestCase {
    func testNativeCancelledDragAndLift() throws {
        continueAfterFailure = false
        try nativeQueueAcceptance(manifest: ProcessInfo.processInfo.environment["HM_NATIVE_ACCEPTANCE_MANIFEST"])
    }
    /// Generated offline media by default; a public HTTP fixture manifest can exercise the cache transport.
    private func nativeQueueAcceptance(manifest: String?) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--hm-regression-feed", "1", "--hm-probe", "1"]
        if let manifest { app.launchArguments += ["--hm-manifest-url", manifest] }
        app.launch()
        let status = app.staticTexts["regression-status"], starts = app.staticTexts["probe-starts"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "label CONTAINS 'displayed'"), evaluatedWith: status)
        waitForExpectations(timeout: 15)
        let origin = status.label.components(separatedBy: "|")[1]
        let baseline = starts.label
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        for delta in [-0.12, 0.12] {
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6 + delta))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.8)
            // A recognized slow drag with a stationary release must settle on origin.
            expectation(for: NSPredicate(format: "label == 'idle'"), evaluatedWith: app.staticTexts["interaction-state"])
            waitForExpectations(timeout: 5)
            XCTAssertEqual(status.label.components(separatedBy: "|")[1], origin)
            XCTAssertEqual(starts.label, baseline) // Includes transient activations, not just final ID.
        }
        app.swipeUp()
        expectation(for: NSPredicate(format: "NOT label CONTAINS %@", "|" + origin + "|"), evaluatedWith: status)
        waitForExpectations(timeout: 8)
        XCTAssertEqual(starts.label.split(separator: ",").count, 2)
        let assignments = app.staticTexts["probe-assignments"].label.split(separator: ",")
        XCTAssertLessThanOrEqual(assignments.count, 2)
        // Pause-burst and back navigation exercise the same retained two-node engine.
        app.buttons["hm-video-surface"].firstMatch.tap()
        app.swipeUp(); app.swipeUp(); app.swipeDown()
        XCTAssertLessThanOrEqual(app.staticTexts["probe-assignments"].label.split(separator: ",").count, 2)

    }

    func testHorizontalRestrictedHost() throws {
        let env = ProcessInfo.processInfo.environment
        guard let manifest = env["HM_HORIZONTAL_MANIFEST"] else { throw XCTSkip("Set HM_HORIZONTAL_MANIFEST for the local horizontal walkthrough") }
        continueAfterFailure = false
        for portraitOnly in [true, false] {
            XCUIDevice.shared.orientation = .portrait
            let app = XCUIApplication()
            app.launchArguments = ["--hm-horizontal-lab", "1", "--hm-manifest-url", manifest, "--hm-start-index", "1"]
            if portraitOnly { app.launchArguments += ["--hm-portrait-only", "1"] }
            app.launch()
            let evidence = app.staticTexts["horizontal-evidence"]
            XCTAssertTrue(evidence.waitForExistence(timeout: 15))
            expectation(for: NSPredicate(format: "label MATCHES %@", ".*\\|[1-9][0-9]*\\|0$"), evaluatedWith: evidence)
            waitForExpectations(timeout: 20)
            let original = evidence.label
            let startup = app.staticTexts["horizontal-ttff"].label.split(separator: " ").dropFirst().first.flatMap { Double($0) }
            XCTAssertLessThan(try XCTUnwrap(startup), 3000) // catches a watcher sleeping until a 12s fixture loops
            let exit = app.buttons["hm-exit-fullscreen"]
            app.buttons["horizontal-fullscreen"].tap()
            XCTAssertTrue(exit.waitForExistence(timeout: 5), "\(app.staticTexts["horizontal-runtime"].label) status=\(app.staticTexts["horizontal-status"].label) ownership=\(evidence.label)")
            XCTAssertTrue(app.staticTexts["horizontal-caption"].exists)
            if portraitOnly { XCTAssertLessThan(app.frame.width, app.frame.height) }
            exit.tap()
            XCTAssertTrue(evidence.waitForExistence(timeout: 5)); XCTAssertEqual(evidence.label, original)
            app.buttons["horizontal-sheet"].tap()
            XCTAssertTrue(app.staticTexts["horizontal-host-sheet"].waitForExistence(timeout: 5))
            app.buttons["sheet-fullscreen"].tap()
            XCTAssertTrue(exit.waitForExistence(timeout: 5), "\(app.staticTexts["horizontal-runtime"].label) status=\(app.staticTexts["horizontal-status"].label) ownership=\(evidence.label)")
            XCTAssertTrue(app.staticTexts["horizontal-caption"].exists)
            if portraitOnly { XCTAssertLessThan(app.frame.width, app.frame.height) }
            exit.tap()
            XCTAssertTrue(app.buttons["close-host-sheet"].waitForExistence(timeout: 5))
            app.buttons["close-host-sheet"].tap()
            XCTAssertTrue(evidence.waitForExistence(timeout: 5)); XCTAssertEqual(evidence.label, original)
            if portraitOnly {
                // The feed scene cannot rotate. Device orientation must still enter fullscreen.
                XCUIDevice.shared.orientation = .landscapeLeft
                XCTAssertTrue(exit.waitForExistence(timeout: 5), "\(app.staticTexts["horizontal-runtime"].label) status=\(app.staticTexts["horizontal-status"].label) ownership=\(evidence.label)")
                XCTAssertLessThan(app.frame.width, app.frame.height)
                XCUIDevice.shared.orientation = .portrait
                XCTAssertTrue(evidence.waitForExistence(timeout: 5)); XCTAssertEqual(evidence.label, original)
            }
            // Begin the swipe immediately after exit, within the restore quiet period.
            app.buttons["horizontal-fullscreen"].tap()
            XCTAssertTrue(exit.waitForExistence(timeout: 5), "\(app.staticTexts["horizontal-runtime"].label) status=\(app.staticTexts["horizontal-status"].label) ownership=\(evidence.label)"); exit.tap()
            app.swipeUp()
            expectation(for: NSPredicate(format: "label CONTAINS '003-portrait'"), evaluatedWith: app.staticTexts["horizontal-status"])
            waitForExpectations(timeout: 10)
            app.terminate()
        }
    }

    /// Opt-in simulator walkthrough; unit coverage remains in the existing native/snapshot suites.
    func testHorizontalFullscreenContinuity() throws {
        let env = ProcessInfo.processInfo.environment
        guard let manifest = env["HM_HORIZONTAL_MANIFEST"] else { throw XCTSkip("Set HM_HORIZONTAL_MANIFEST for the local horizontal walkthrough") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--hm-horizontal-lab", "1", "--hm-manifest-url", manifest, "--hm-start-index", "1"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let status = app.staticTexts["horizontal-status"], evidence = app.staticTexts["horizontal-evidence"]
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        let displayed = NSPredicate(format: "label MATCHES %@", ".*\\|[1-9][0-9]*\\|0$")
        expectation(for: displayed, evaluatedWith: evidence)
        expectation(for: NSPredicate(format: "NOT label CONTAINS 'pending'"), evaluatedWith: app.staticTexts["horizontal-ttff"])
        waitForExpectations(timeout: 20)
        let original = evidence.label
        let startup = app.staticTexts["horizontal-ttff"].label.split(separator: " ").dropFirst().first.flatMap { Double($0) }
        XCTAssertLessThan(try XCTUnwrap(startup), 3000)
        func shot(_ name: String) throws {
            // Wait for UIKit's rotation animation, then capture the whole display.
            // app.screenshot() can crop to the old portrait app bounds during rotation.
            Thread.sleep(forTimeInterval: 0.8)
            if name.contains("fullscreen") {
                // Detect presentation inheriting the host's intermediate portrait transform.
                XCTAssertGreaterThan(app.frame.width, app.frame.height)
                let exitFrame = app.buttons["hm-exit-fullscreen"].frame
                XCTAssertGreaterThan(exitFrame.midX, app.frame.midX)
                XCTAssertLessThan(exitFrame.midY, app.frame.midY)
            }
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            if let path = env["HM_HORIZONTAL_SHOTS"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try screenshot.pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"))
            }
        }
        try shot("feed-landscape-mp4")
        app.buttons["horizontal-fullscreen"].tap()
        let exit = app.buttons["hm-exit-fullscreen"]
        XCTAssertTrue(exit.waitForExistence(timeout: 5), "\(app.staticTexts["horizontal-runtime"].label) status=\(app.staticTexts["horizontal-status"].label) ownership=\(evidence.label)")
        try shot("feed-fullscreen-api")
        app.swipeUp() // fullscreen must not page the feed
        exit.tap()
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(evidence.label, original)
        try shot("feed-return-api")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(exit.waitForExistence(timeout: 5), "\(app.staticTexts["horizontal-runtime"].label) status=\(app.staticTexts["horizontal-status"].label) ownership=\(evidence.label)")
        try shot("feed-fullscreen-rotation")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(evidence.label, original)
        try shot("feed-return-rotation")
        app.buttons["horizontal-inline"].tap()
        XCTAssertTrue(app.staticTexts["Inline 16:9 player"].waitForExistence(timeout: 5))
        try shot("standalone-inline")
        app.buttons["horizontal-fullscreen"].tap()
        XCTAssertTrue(exit.waitForExistence(timeout: 5), "\(app.staticTexts["horizontal-runtime"].label) status=\(app.staticTexts["horizontal-status"].label) ownership=\(evidence.label)")
        try shot("standalone-fullscreen")
        exit.tap()
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(evidence.label, original)
        try shot("standalone-return")
        // HLS landscape and vertical rotation behavior use the same rendering route.
        app.buttons["horizontal-inline"].tap()
        let frames = Int(original.split(separator: "|")[2])!
        app.buttons["Next"].tap()
        expectation(for: NSPredicate(format: "label MATCHES %@", ".*\\|\(frames + 1)\\|0$"), evaluatedWith: evidence)
        waitForExpectations(timeout: 15)
        app.buttons["Next"].tap()
        expectation(for: NSPredicate(format: "label CONTAINS '004-landscape'"), evaluatedWith: status)
        waitForExpectations(timeout: 10)
        expectation(for: NSPredicate(format: "label MATCHES %@", ".*\\|\(frames + 2)\\|0$"), evaluatedWith: evidence)
        waitForExpectations(timeout: 15)
        let hls = evidence.label
        try shot("feed-landscape-hls")
        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(exit.waitForExistence(timeout: 5), "\(app.staticTexts["horizontal-runtime"].label) status=\(app.staticTexts["horizontal-status"].label) ownership=\(evidence.label)")
        try shot("feed-hls-fullscreen-rotation")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(evidence.label, hls)
        app.buttons["Previous"].tap()
        expectation(for: NSPredicate(format: "label CONTAINS '003-portrait'"), evaluatedWith: status)
        expectation(for: NSPredicate(format: "label MATCHES %@", ".*\\|\(frames + 3)\\|0$"), evaluatedWith: evidence)
        waitForExpectations(timeout: 10)
        let portrait = evidence.label
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertFalse(exit.waitForExistence(timeout: 2))
        XCUIDevice.shared.orientation = .portrait
        try shot("feed-portrait-hls")
        XCTAssertEqual(evidence.label, portrait) // resizing a portrait feed must not page either
    }

}
