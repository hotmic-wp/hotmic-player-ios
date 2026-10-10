import XCTest

/// Always runnable with generated offline media; no opt-in environment or remote services.
final class PartnerDemoUITests: XCTestCase {
    func testSocialGesturesAndSheet() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--hm-partner-demo", "1"]
        app.launch()
        // Scope controls to the current overlay, since the feed prewarms adjacent cells.
        let overlay = app.descendants(matching: .any)["hm-current-social-overlay"].firstMatch
        let fire = overlay.buttons["hm-fire"]
        XCTAssertTrue(fire.waitForExistence(timeout: 25))
        let surface = app.buttons["hm-video-surface"]
        func expectValue(_ element: XCUIElement, contains text: String) {
            expectation(for: NSPredicate(format: "value CONTAINS %@", text), evaluatedWith: element)
            waitForExpectations(timeout: 8)
        }
        expectValue(surface, contains: "Playing")
        let emptyVideo = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.27))
        emptyVideo.tap()
        expectValue(surface, contains: "Paused")
        emptyVideo.doubleTap()
        expectation(for: NSPredicate(format: "value BEGINSWITH %@", "reacted"), evaluatedWith: fire)
        waitForExpectations(timeout: 8)
        expectValue(surface, contains: "Paused")
        fire.tap()
        expectValue(fire, contains: "not reacted")
        expectValue(fire, contains: "reactions")
        expectValue(overlay.buttons["hm-comments"], contains: "6")
        overlay.buttons["Hashtag Highlights"].tap()
        XCTAssertEqual(app.staticTexts["partner-notice"].label, "Hashtag: Highlights")
        let preview = overlay.buttons["hm-comment-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 8))
        preview.tap()
        let close = app.buttons["hm-close-comments"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let handle = app.descendants(matching: .any)["hm-comment-handle"].firstMatch
        XCTAssertTrue(handle.exists)
        let drag = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        drag.press(forDuration: 0.1, thenDragTo: drag.withOffset(CGVector(dx: 0, dy: -60)))
        let input = app.descendants(matching: .any)["hm-comment-input"].firstMatch
        XCTAssertTrue(input.exists)
        input.tap()
        let focused = XCTAttachment(screenshot: app.screenshot())
        focused.name = "comment-composer-layout"; focused.lifetime = .keepAlways; add(focused)
        XCTAssertLessThanOrEqual(surface.frame.maxY, handle.frame.minY + 24)
        input.typeText("Great moment")
        app.buttons["hm-post-comment"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Great moment")).firstMatch.waitForExistence(timeout: 8))
        close.tap()
        XCTAssertTrue(fire.waitForExistence(timeout: 5))
        expectValue(surface, contains: "Paused")
        Thread.sleep(forTimeInterval: 0.4)
        emptyVideo.tap()
        expectValue(surface, contains: "Playing")
        overlay.buttons["hm-share"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.cells["Copy"].firstMatch.exists)
        app.buttons["header.closeButton"].firstMatch.tap()
        // Metadata has no nested vertical scroller: this drag must page the feed.
        let metadata = overlay.buttons["Hashtag Highlights"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        metadata.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        expectation(for: NSPredicate(format: "label == %@", "The whole field, in view"), evaluatedWith: surface)
        waitForExpectations(timeout: 8)
        app.swipeDown()
        expectation(for: NSPredicate(format: "label == %@", "A moment to share"), evaluatedWith: surface)
        waitForExpectations(timeout: 8)
        expectValue(fire, contains: "not reacted")
    }
}
