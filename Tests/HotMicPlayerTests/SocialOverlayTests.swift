#if os(iOS)
import XCTest
import Observation
import HotMicPlayer
@testable import HotMicPlayerUI

@MainActor final class SocialOverlayTests: XCTestCase {
    func testSheetGuardsAndBalancedOriginCallbacks() {
        let state = HMSocialState()
        let first = HMMediaItem(id: "first", url: URL(string: "https://example.com/first.mp4")!)
        let second = HMMediaItem(id: "second", url: URL(string: "https://example.com/second.mp4")!)
        var events: [String] = []
        let callback: (HMMediaItem, Bool) -> Void = { events.append("\($0.id):\($1)") }
        state.openComments(item: first, height: 380, isAdActive: true, onChange: callback)
        XCTAssertFalse(state.isSheetOpen)
        state.updateSheetLayout(maximumHeight: 300, bottomInset: 88)
        state.openComments(item: first, height: 380, isAdActive: false, onChange: callback)
        XCTAssertEqual(state.sheetHeight, 300)
        state.openComments(item: second, height: 380, isAdActive: false, onChange: callback)
        state.dragComments(to: 220)
        XCTAssertEqual(state.sheetHeight, 220)
        state.updateSheetLayout(maximumHeight: 180, bottomInset: 340)
        XCTAssertEqual(state.sheetHeight, 180)
        XCTAssertEqual(state.sheetBottomInset, 340)
        state.dragComments(to: 600)
        XCTAssertEqual(state.sheetHeight, 180)
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
        var completed = expectation(description: "reaction completes")
        data.onSetReacted = { memberships.append($0); data.content.isReacted = $0; completed.fulfill() }
        state.fireTarget = CGPoint(x: 300, y: 400)
        state.fire(at: nil, item: item, data: data)
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(state.fireOrigin, state.fireTarget)
        XCTAssertEqual(memberships, [true])
        completed = expectation(description: "double tap completes")
        state.fire(at: CGPoint(x: 30, y: 40), item: item, data: data, addOnly: true)
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(state.fireID, 2)
        XCTAssertEqual(state.fireOrigin, CGPoint(x: 30, y: 40))
        XCTAssertTrue(data.content.isReacted)
        completed = expectation(description: "un-react completes")
        state.fire(at: nil, item: item, data: data)
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(memberships, [true, true, false])
        state.fire(at: nil, item: item, data: data, isAdActive: true)
        state.openComments(item: item, height: 380, isAdActive: false)
        state.fire(at: nil, item: item, data: data)
        XCTAssertEqual(state.fireID, 2) // Un-react never creates a burst event.
        XCTAssertFalse(state.fireIsPositive)
    }
    func testAdapterThemeAndMappingCacheInvalidateOnPublicRevisions() async throws {
        let item = HMMediaItem(id: "item", url: URL(string: "https://example.com/clip.mp4")!)
        let source = EngagementTests.ItemSource()
        let engagement = HMEngagement(item: item, timeline: source.timeline(for: item), source: source)
        try await engagement.loadComments()
        engagement.updateReactionSummary(.init(count: 42, reactedByViewer: false), for: "💜")
        engagement.updateReactionSummary(.init(count: 7, reactedByViewer: true), for: "🔥")
        var theme = HMTheme.default; theme.reactionPalette = ["💜"]
        var mappings = 0
        let adapter = HMEngagementSocialAdapter(engagement: engagement, metadata: .init(title: "Moment"), theme: theme,
            previewSelection: { rows in mappings += 1; return rows })
        XCTAssertEqual(mappings, 0) // Construction and cached, inactive instances do no mapping.
        XCTAssertEqual(adapter.content.fireCount, 42)
        XCTAssertFalse(adapter.content.isReacted)
        XCTAssertEqual(mappings, 1)
        try await adapter.setReacted(true)
        XCTAssertEqual(engagement.reactionSummary(for: "💜")?.reactedByViewer, true)
        await settleAdapter()
        XCTAssertTrue(adapter.content.isReacted)
        let priorMappings = mappings
        engagement.updateCommentCount(99)
        await settleAdapter()
        XCTAssertEqual(adapter.content.commentCount, 99)
        XCTAssertEqual(mappings, priorMappings + 1)
        adapter.theme = .default
        await settleAdapter()
        XCTAssertEqual(adapter.content.fireCount, 7)
        adapter.metadata.title = "Updated"
        await settleAdapter()
        XCTAssertEqual(adapter.content.title, "Updated")
        adapter.previewSelection = { _ in mappings += 1; return [] }
        await settleAdapter()
        _ = adapter.content
        let finalMappings = mappings
        _ = adapter.content
        XCTAssertEqual(mappings, finalMappings)
    }

    private func settleAdapter() async {
        for _ in 0..<10 { await Task.yield() }
    }

    @Observable final class Clock {
        var time: TimeInterval = 0
        var invalidations = 0
        var reads = 0
    }

    func testReplayClockPublishesOnlyChangedRowsWithoutCommentPaging() async {
        let clock = Clock()
        let item = HMMediaItem(id: "replay", url: URL(string: "https://example.com/replay.mp4")!)
        let timeline = EngagementTests.FixtureTimeline(duration: 12, events: [
            .init(id: "at-two", offset: 2, kind: .chat, author: "Fan", text: "Great play")
        ])
        let engagement = HMEngagement(item: item, timeline: timeline, source: nil, mediaClock: { clock.reads += 1; return clock.time })
        let adapter = HMEngagementSocialAdapter(engagement: engagement, metadata: .init(title: "Replay"))
        XCTAssertEqual(clock.reads, 0)
        _ = adapter.content
        XCTAssertEqual(clock.reads, 0) // Lazy mapping never observes the player clock.
        adapter.setReplayActive(true)
        let changed = expectation(description: "rows change at timestamp")
        withObservationTracking { _ = adapter.content } onChange: {
            MainActor.assumeIsolated { clock.invalidations += 1; changed.fulfill() }
        }
        clock.time = 0.2
        await settleAdapter()
        clock.time = 1.8
        await settleAdapter()
        XCTAssertTrue(adapter.content.comments.isEmpty)
        XCTAssertEqual(clock.invalidations, 0)
        // A clock-only publication would fulfill before the row boundary.
        clock.time = 2.1
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(adapter.content.comments.map(\.id), ["at-two"])
        let unchanged = expectation(description: "steady replay rows do not invalidate chrome")
        unchanged.isInverted = true
        withObservationTracking { _ = adapter.content } onChange: { unchanged.fulfill() }
        clock.time = 2.3
        await settleAdapter()
        clock.time = 3
        await fulfillment(of: [unchanged], timeout: 0.15)
        adapter.setReplayActive(false)
        let reads = clock.reads
        clock.time = 0
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(adapter.content.comments.map(\.id), ["at-two"])
        XCTAssertEqual(clock.reads, reads)
    }

}
#endif
