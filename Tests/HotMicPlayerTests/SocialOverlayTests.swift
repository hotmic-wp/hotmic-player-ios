#if os(iOS)
import XCTest
import HotMicPlayer
import HotMicPlayerUI

@MainActor final class SocialOverlayTests: XCTestCase {
    func testSheetGuardsAndBalancedOriginCallbacks() {
        let state = HMSocialState()
        let first = HMMediaItem(id: "first", url: URL(string: "https://example.com/first.mp4")!)
        let second = HMMediaItem(id: "second", url: URL(string: "https://example.com/second.mp4")!)
        var events: [String] = []
        let callback: (HMMediaItem, Bool) -> Void = { events.append("\($0.id):\($1)") }
        state.openComments(item: first, height: 380, isAdActive: true, onChange: callback)
        XCTAssertFalse(state.isSheetOpen)
        state.openComments(item: first, height: 380, isAdActive: false, onChange: callback)
        state.openComments(item: second, height: 380, isAdActive: false, onChange: callback)
        state.dragComments(to: 220)
        XCTAssertEqual(state.sheetHeight, 220)
        state.closeComments(); state.closeComments()
        XCTAssertEqual(events, ["first:true", "first:false"])
        state.dragComments(to: 400)
        XCTAssertEqual(state.sheetHeight, 0)
    }

    func testFireInputsShareOneEventAndAdSheetGates() async {
        let state = HMSocialState()
        let item = HMMediaItem(id: "item", url: URL(string: "https://example.com/clip.mp4")!)
        let data = HMSocialModel(content: HMSocialContent(title: "Moment"))
        var memberships: [Bool] = []
        data.onSetReacted = { memberships.append($0); data.content.isReacted = $0 }
        state.fireTarget = CGPoint(x: 300, y: 400)
        state.fire(at: nil, item: item, data: data)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(state.fireOrigin, state.fireTarget)
        XCTAssertEqual(memberships, [true])
        state.fire(at: CGPoint(x: 30, y: 40), item: item, data: data, addOnly: true)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(state.fireID, 2)
        XCTAssertEqual(state.fireOrigin, CGPoint(x: 30, y: 40))
        XCTAssertTrue(data.content.isReacted)
        state.fire(at: nil, item: item, data: data)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(memberships, [true, true, false])
        state.fire(at: nil, item: item, data: data, isAdActive: true)
        state.openComments(item: item, height: 380, isAdActive: false)
        state.fire(at: nil, item: item, data: data)
        XCTAssertEqual(state.fireID, 3)
    }
}
#endif
