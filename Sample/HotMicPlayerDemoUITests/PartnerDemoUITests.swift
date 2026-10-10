import XCTest

/// Always runnable with generated offline media; no opt-in environment or remote services.
final class PartnerDemoUITests: XCTestCase {
    func testSocialGesturesAndSheet() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--hm-partner-demo", "1"]
        app.launch()
        let fire = app.buttons["hm-fire"]
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
        expectation(for: NSPredicate(format: "value == %@", "reacted"), evaluatedWith: fire)
        waitForExpectations(timeout: 8)
        expectValue(surface, contains: "Paused")
        fire.tap()
        expectValue(fire, contains: "not reacted")
        app.buttons["Hashtag Highlights"].tap()
        XCTAssertEqual(app.staticTexts["partner-notice"].label, "Hashtag: Highlights")
        let preview = app.buttons["hm-comment-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 8))
        preview.tap()
        let close = app.buttons["hm-close-comments"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertFalse(fire.isHittable)
        let handle = app.descendants(matching: .any)["hm-comment-handle"].firstMatch
        XCTAssertTrue(handle.exists)
        let drag = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        drag.press(forDuration: 0.1, thenDragTo: drag.withOffset(CGVector(dx: 0, dy: -60)))
        let input = app.descendants(matching: .any)["hm-comment-input"].firstMatch
        XCTAssertTrue(input.exists)
        input.tap(); input.typeText("Great moment")
        app.buttons["hm-post-comment"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Great moment")).firstMatch.waitForExistence(timeout: 8))
        close.tap()
        XCTAssertTrue(fire.waitForExistence(timeout: 5))
        expectValue(surface, contains: "Paused")
        Thread.sleep(forTimeInterval: 0.4)
        emptyVideo.tap()
        expectValue(surface, contains: "Playing")
        app.buttons["hm-share"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.cells["Copy"].firstMatch.exists)
    }
}
