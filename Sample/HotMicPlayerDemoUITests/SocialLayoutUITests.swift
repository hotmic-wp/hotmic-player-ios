import XCTest

/// Exercises native recognizers with offline generated media, without opt-in environment variables.
final class SocialLayoutUITests: XCTestCase {
    func testVideoGestures() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--hm-social-layout", "1", "--hm-social-fixture", "1"]
        app.launch()
        let status = app.staticTexts["social-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 20))
        func expect(_ text: String) {
            expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: status)
            waitForExpectations(timeout: 5)
        }
        expect("playing · taps 0 · fire 0")
        let video = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        video.tap()
        expect("paused · taps 1 · fire 0")
        video.doubleTap()
        expect("paused · taps 1 · fire 1")
        // Wait for the Fire continuation window to close before beginning a new triple tap.
        Thread.sleep(forTimeInterval: 0.4)
        app.buttons["hm-video-surface"].tap(withNumberOfTaps: 3, numberOfTouches: 1)
        expect("paused · taps 1 · fire 3")
        Thread.sleep(forTimeInterval: 0.4)
        let link = app.buttons["social-metadata-link"]
        XCTAssertTrue(link.exists); link.tap()
        expect("paused · taps 1 · fire 3 · links 1")
        // Noninteractive gap inside the rail's HMHitArea is excluded as well.
        let share = app.buttons["social-share"].frame
        let fullscreen = app.buttons["social-fullscreen"].frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: share.midX, dy: (share.maxY + fullscreen.minY) / 2)).doubleTap()
        Thread.sleep(forTimeInterval: 0.5)
        // Host controls can handle their own touch slop; neither video callback may run.
        let videoStatus = Array(status.label.components(separatedBy: " · ").prefix(3))
        XCTAssertEqual(videoStatus, ["paused", "taps 1", "fire 3"], "Video callbacks changed inside an excluded rail")
        video.tap(); expect("playing · taps 2 · fire 3")
    }
}
