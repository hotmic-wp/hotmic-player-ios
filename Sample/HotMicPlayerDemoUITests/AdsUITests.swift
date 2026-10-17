import XCTest

/// Offline integration contract across the shared surfaces; no network SDK calls.
final class AdsUITests: XCTestCase {
    func testAdsInFeedAndStandalone() {
        continueAfterFailure = false
        for inline in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--hm-ads-lab", "1"] + (inline ? ["--hm-ads-inline", "1"] : [])
            app.launch()
            let active = app.staticTexts["ads-active"], comments = app.buttons["ads-comments"]
            XCTAssertTrue(active.waitForExistence(timeout: 15))
            XCTAssertFalse(comments.exists)
            XCTAssertFalse(app.staticTexts["ads-preview"].exists)
            XCTAssertFalse(app.buttons["ads-squeeze"].exists)
            let video = app.otherElements["Video"]
            XCTAssertFalse(video.exists) // video's accessibility actions are suppressed automatically
            if inline { app.buttons["ads-skip"].tap() }
            else { XCTAssertTrue(comments.waitForExistence(timeout: 9)) } // real media-end notification
            XCTAssertTrue(comments.waitForExistence(timeout: 5))
            app.buttons["ads-next"].tap()
            XCTAssertTrue(active.waitForExistence(timeout: 5))
            XCTAssertFalse(comments.exists)
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = inline ? "standalone-host-ad" : "feed-host-ad"; shot.lifetime = .keepAlways; add(shot)
            if inline { app.buttons["ads-skip"].tap() }
            else { app.swipeUp() } // default swipe-away cancellation while the host break plays
            if inline { app.buttons["ads-next"].tap() }
            XCTAssertTrue(comments.waitForExistence(timeout: 7)) // slow provider times out to content
            XCTAssertTrue(app.staticTexts["ads-status"].label.contains("slow-ad"))
            app.terminate()
        }
    }
    func testURLCompanionPinsAcrossASwipeAndKeepsCommentsLive() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--hm-ads-lab", "1", "--hm-start-index", "6", "--hm-ads-companion-watched", "2", "--hm-ads-companion-countdown", "1"]
        app.launch()
        let comments = app.buttons["ads-comments"], companion = app.staticTexts["ads-companion"]
        XCTAssertTrue(comments.waitForExistence(timeout: 15)) // content starts at once: no pre-roll suppression
        XCTAssertTrue(app.staticTexts["ads-companion-countdown"].waitForExistence(timeout: 10))
        XCTAssertTrue(companion.waitForExistence(timeout: 10))
        XCTAssertTrue(comments.exists) // comments stay available beside the companion
        XCTAssertTrue(app.otherElements["hm-companion-band"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "feed-companion"; shot.lifetime = .keepAlways; add(shot)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["ads-status"].waitForExistence(timeout: 5))
        XCTAssertTrue(companion.exists) // pinned across the swipe
        app.buttons["ads-companion-mute"].tap() // unmute holds content
        XCTAssertTrue(app.buttons["ads-companion-mute"].label.contains("Mute"))
        app.terminate()
    }
}
