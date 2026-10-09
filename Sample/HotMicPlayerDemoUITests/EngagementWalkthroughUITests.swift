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
        guard mode != "scrub" else { throw XCTSkip("scrub mode runs testScrubCancellation") }
        app = XCUIApplication()
        app.launchArguments = ["--hm-open-feed", "0", "--hm-hud", "0"]
        if let origin = env["HM_FEED_HLS_ORIGIN"] { app.launchArguments += ["--hm-feed-hls-origin", origin] }
        if mode == "moderation" { app.launchArguments += ["--hm-moderation", "1"] }
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
        if mode == "moderation" {
            XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3), "moderation walkthrough must stay paused")
        }

        switch mode {
        case "moderation":
            try moderationWalkthrough()
            return
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

    private func moderationWalkthrough() throws {
        shot("moderation-before")
        app.buttons["moderation-poll"].tap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(app.otherElements["Poll"].firstMatch.exists, "deleted poll stayed on screen")
        shot("moderation-poll-removed")

        app.buttons["moderation-newest"].tap()
        let status = app.staticTexts["moderation-status"]
        XCTAssertTrue(status.label.hasPrefix("Deleted newest:"), status.label)
        let deletedText = String(status.label.dropFirst("Deleted newest: ".count))
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", deletedText)).firstMatch.exists,
                       "deleted incoming message stayed on screen")
        shot("moderation-newest-removed")

        app.buttons["Comment"].firstMatch.tap()
        let field = app.textFields["Comment"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("Moderate my confirmed message")
        app.buttons["Send"].firstMatch.tap()
        let own = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'You: Moderate my confirmed message'")).firstMatch
        XCTAssertTrue(own.waitForExistence(timeout: 3))
        shot("moderation-own-confirmed")
        app.buttons["moderation-own"].tap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(own.exists, "confirmed own message survived moderation")
        XCTAssertTrue(status.label.hasPrefix("Deleted mine:"), status.label)
        shot("moderation-own-removed")

        let peaks = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Moment at'"))
        let before = peaks.allElementsBoundByIndex.map(\.label)
        app.buttons["moderation-peak"].tap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(status.label, "Deleted peak reactions")
        XCTAssertNotEqual(peaks.allElementsBoundByIndex.map(\.label), before, "waveform peaks did not update")
        shot("moderation-peak-removed")
    }

    /// Scrub cancellation: a drag on the scrubber that turns into a page swipe, a drag that returns
    /// and completes, and a press interrupted by backgrounding (the host opens Settings when
    /// `scrub-hold.signal` appears). After each, the player must not be left interacting and the
    /// rail must be back at rest. Runs with `HM_WALK_MODE=scrub`.
    func testScrubCancellation() throws {
        guard ProcessInfo.processInfo.environment["HM_WALK_MODE"] == "scrub" else { throw XCTSkip("HM_WALK_MODE=scrub") }
        app = XCUIApplication()
        app.launchArguments = ["--hm-open-feed", "0", "--hm-hud", "0", "--hm-probe", "1"]
        app.launch()
        let state = app.staticTexts["interaction-state"]
        let scrubber = app.otherElements["Playback position"].firstMatch
        XCTAssertTrue(scrubber.waitForExistence(timeout: 20))
        let moment = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Moment at'")).firstMatch
        XCTAssertTrue(moment.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        let restingMarkerY = moment.frame.midY
        XCTAssertEqual(state.label, "idle")

        // 1. A vertical drag that starts on the scrubber stays a scrub (the feed doesn't take the
        //    pan) and ends cleanly.
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        Thread.sleep(forTimeInterval: 1.5)
        shot("scrub-vertical-drag")
        XCTAssertTrue(waitFor(state, "idle"), "interaction stuck after a vertical drag: \(state.label)")
        XCTAssertEqual(moment.frame.midY, restingMarkerY, accuracy: 2)

        // 1b. The cell scrolls away mid-scrub: the host pages forward while the press is held.
        try Data().write(to: directory.appendingPathComponent("scrub-next.signal"))
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press(forDuration: 5)
        Thread.sleep(forTimeInterval: 1.5)
        shot("scrub-swiped-away")
        XCTAssertTrue(waitFor(state, "idle"), "interaction stuck after the cell scrolled away mid-scrub: \(state.label)")
        let onScreen = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'One-handed grab'"))
            .allElementsBoundByIndex.contains { $0.frame.minY > 0 && $0.frame.maxY < app.frame.maxY }
        XCTAssertTrue(onScreen, "feed did not page while scrubbing")
        app.swipeDown(velocity: .fast)
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertTrue(waitFor(state, "idle"))
        let back = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Moment at'")).firstMatch
        XCTAssertEqual(back.frame.midY, restingMarkerY, accuracy: 2, "rail left expanded on the cell that scrolled away")
        shot("scrub-swiped-back")

        // 2. A completed horizontal scrub still seeks and ends the interaction.
        let before = scrubber.value as? String ?? ""
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(forDuration: 0.2, thenDragTo: scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        XCTAssertTrue(waitFor(state, "idle"))
        XCTAssertNotEqual(scrubber.value as? String ?? "", before, "completed scrub did not seek")
        XCTAssertEqual(moment.frame.midY, restingMarkerY, accuracy: 2)

        // 3. Backgrounded mid-press: the host opens Settings while the press is held.
        try Data().write(to: directory.appendingPathComponent("scrub-hold.signal"))
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).press(forDuration: 6)
        app.activate()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(waitFor(state, "idle"), "interaction stuck after backgrounding mid-scrub: \(state.label)")
        let afterBackground = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Moment at'")).firstMatch
        XCTAssertEqual(afterBackground.frame.midY, restingMarkerY, accuracy: 2, "rail left expanded after backgrounding")
        shot("scrub-after-background")
    }

    private func waitFor(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.label == label { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    /// Taps empty video above the overlay content, which toggles playback.
    private func togglePlayback() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.32)).tap()
    }

    private func shot(_ name: String) {
        let data = app.screenshot().pngRepresentation
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        try? data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
