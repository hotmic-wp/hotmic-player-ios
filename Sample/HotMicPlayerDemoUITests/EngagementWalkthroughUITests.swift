import XCTest

/// Drives the engagement overlay through the real feed with real touches and
/// saves a PNG per state into `HM_SHOT_DIR` (pass `TEST_RUNNER_HM_SHOT_DIR` to
/// xcodebuild). This is simulator evidence for docs/screenshots, not a
/// regression test: it skips unless a directory is supplied.
///
/// `HM_WALK_MODE`: `main` (default) walks every flow; `light` and `xl` capture
/// the poll in light mode and at Dynamic Type XL. `HM_FEED_HLS_ORIGIN` mixes the
/// HLS rendition into the feed as item two.
final class EngagementWalkthroughUITests: XCTestCase {

    private var directory: URL!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let path = ProcessInfo.processInfo.environment["HM_SHOT_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_HM_SHOT_DIR to capture the walkthrough")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func testWalkthrough() throws {
        let env = ProcessInfo.processInfo.environment
        let mode = env["HM_WALK_MODE"] ?? "main"
        app = XCUIApplication()
        app.launchArguments = ["--hm-open-feed", "0", "--hm-hud", "0"]
        if let origin = env["HM_FEED_HLS_ORIGIN"] { app.launchArguments += ["--hm-feed-hls-origin", origin] }
        if mode == "light" { app.launchArguments += ["--hm-appearance", "light"] }
        if mode == "xl" { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXL"] }
        app.launch()

        let scrubber = app.otherElements["Playback position"].firstMatch
        XCTAssertTrue(scrubber.waitForExistence(timeout: 20), "feed did not open")

        // The mock poll opens at 20% of the clip; pause inside its window so
        // the capture and the vote are not racing the clock.
        let poll = app.otherElements["Poll"].firstMatch
        XCTAssertTrue(poll.waitForExistence(timeout: 15), "poll never appeared")
        Thread.sleep(forTimeInterval: 1.2)
        togglePlayback()
        Thread.sleep(forTimeInterval: 0.6)

        switch mode {
        case "light":
            shot("light-poll")
            return
        case "xl":
            shot("dynamic-type-xl")
            return
        default:
            shot("overlay-mp4")
        }

        // Vote: tap the first answer, then the card flips to results.
        let option = poll.buttons.firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 3))
        option.tap()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(poll.staticTexts.containing(NSPredicate(format: "label CONTAINS 'percent'")).firstMatch.exists
                      || poll.otherElements.containing(NSPredicate(format: "label CONTAINS 'your vote'")).firstMatch.exists
                      || app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'your vote'")).firstMatch.exists,
                      "poll did not show results")
        shot("poll-voted")
        togglePlayback()

        // Tap the first waveform peak: playback jumps to it.
        let moment = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Moment at'")).firstMatch
        XCTAssertTrue(moment.waitForExistence(timeout: 5))
        let before = scrubber.value as? String ?? ""
        moment.tap()
        Thread.sleep(forTimeInterval: 1.0)
        shot("marker-seek")
        XCTAssertNotEqual(scrubber.value as? String ?? "", before, "peak tap did not seek")

        // Scrub back to the start: the chat rail rewinds with it.
        let start = scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        start.press(forDuration: 0.15, thenDragTo: scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)))
        Thread.sleep(forTimeInterval: 0.5)
        shot("scrub-back")

        // Send a chat; it lands at the current media time.
        let comment = app.buttons["Comment"].firstMatch
        XCTAssertTrue(comment.waitForExistence(timeout: 3))
        comment.tap()
        let field = app.textFields["Comment"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("Running this one back 🔁")
        Thread.sleep(forTimeInterval: 0.6)
        shot("composer")
        app.buttons["Send"].firstMatch.tap()
        let sent = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'You: Running this one back'")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 3), "own message did not appear")
        Thread.sleep(forTimeInterval: 0.6)
        shot("chat-sent")
        // The composer closes on send. Swipe: the next item brings its own engagement.

        app.swipeUp(velocity: .fast)
        Thread.sleep(forTimeInterval: 3.5)
        shot("next-item")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'You: Running this one back'")).firstMatch.exists,
                       "previous item's chat leaked into the next item")

        app.swipeUp(velocity: .fast)
        Thread.sleep(forTimeInterval: 3.5)
        shot("third-item")
    }

    /// Taps empty video above the overlay content, which toggles playback.
    private func togglePlayback() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.22)).tap()
    }

    private func shot(_ name: String) {
        let data = app.screenshot().pngRepresentation
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        try? data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
