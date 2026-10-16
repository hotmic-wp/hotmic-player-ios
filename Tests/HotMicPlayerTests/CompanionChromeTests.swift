#if os(iOS)
import XCTest
import SwiftUI
@testable import HotMicPlayer
@testable import HotMicPlayerUI

/// Rule 22: the kit lifts its resting chrome, preview and sheet by the companion band.
@MainActor final class CompanionChromeTests: XCTestCase {
    func testCompanionBandLiftsSheetGeometryAboveHostNavigation() {
        let mode = HMSocialOptions.SheetMode.snapped(squeezeFraction: 1.0 / 3)
        let plain = HMSocialState.sheetGeometry(fullHeight: 844, safeTop: 59, safeBottom: 34, navigationHeight: 54, keyboard: 0, companionBand: 0, mode: mode)
        let band: CGFloat = 219.375
        let lifted = HMSocialState.sheetGeometry(fullHeight: 844, safeTop: 59, safeBottom: 34, navigationHeight: 54, keyboard: 0, companionBand: band, mode: mode)
        XCTAssertEqual(plain.bottom, 88)
        XCTAssertEqual(plain.sheetBottom, 88)
        XCTAssertEqual(plain.squeezed ?? -1, (844 - 88) * 2 / 3, accuracy: 0.001)
        XCTAssertEqual(plain.maximum, 844 - 59 - 88)
        // The bottom anchor is nav plus the band, the maximum shrinks, and the squeezed rest height is measured above the band.
        XCTAssertEqual(lifted.bottom, 88 + band)
        XCTAssertEqual(lifted.sheetBottom, 88 + band)
        XCTAssertEqual(lifted.maximum, plain.maximum - band)
        XCTAssertEqual(lifted.squeezed ?? -1, (844 - 88 - band) * 2 / 3, accuracy: 0.001)
        // Keyboard clearance is unchanged by the band: the sheet still clears the keyboard, the rest height does not.
        let keyboard = HMSocialState.sheetGeometry(fullHeight: 844, safeTop: 59, safeBottom: 34, navigationHeight: 54, keyboard: 400, companionBand: band, mode: mode)
        XCTAssertEqual(keyboard.sheetBottom, 400)
        XCTAssertEqual(keyboard.squeezed, lifted.squeezed)
        XCTAssertEqual(keyboard.maximum, 844 - 59 - 400)
        // Continuous sheets keep their handle gap and report no rest height.
        let continuous = HMSocialState.sheetGeometry(fullHeight: 844, safeTop: 59, safeBottom: 34, navigationHeight: 0, keyboard: 0, companionBand: band, mode: .continuous)
        XCTAssertNil(continuous.squeezed)
        XCTAssertEqual(continuous.maximum, 844 - 59 - 34 - band - 24)
        // Invalid band heights count as no band.
        XCTAssertEqual(HMSocialState.sheetGeometry(fullHeight: 844, safeTop: 59, safeBottom: 34, navigationHeight: 54, keyboard: 0, companionBand: .nan, mode: mode), plain)
        XCTAssertEqual(HMSocialState.sheetGeometry(fullHeight: 844, safeTop: 59, safeBottom: 34, navigationHeight: 54, keyboard: 0, companionBand: -10, mode: mode), plain)
    }

    func testStateRecordsTheBandAndTheProgressFrameForTheCountdownPill() {
        let state = HMSocialState()
        XCTAssertEqual(state.companionBandHeight, 0)
        state.updateCompanionBand(height: 100)
        XCTAssertEqual(state.companionBandHeight, 100)
        state.updateCompanionBand(height: .infinity)
        XCTAssertEqual(state.companionBandHeight, 0)
        XCTAssertNil(state.progressBarFrame(for: "item"))
        state.recordProgressBarFrame(CGRect(x: 16, y: 700, width: 300, height: 24), for: "item")
        XCTAssertEqual(state.progressBarFrame(for: "item"), CGRect(x: 16, y: 700, width: 300, height: 24))
        XCTAssertNil(state.progressBarFrame(for: "other"))
    }
}
#endif
