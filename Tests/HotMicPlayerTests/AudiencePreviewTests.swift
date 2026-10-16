#if os(iOS)
import XCTest
import SwiftUI
import Observation
@testable import HotMicPlayer
@testable import HotMicPlayerUI

/// Comment-preview selection and the audience badge: a serializable rule applied to an oldest-first list,
/// and pushed latest-value counts that reach the overlay without any clock.
@MainActor final class AudiencePreviewTests: XCTestCase {
    private func comment(_ number: Int) -> HMSocialComment {
        HMSocialComment(id: "c\(number)", author: "Fan \(number)", text: "Comment \(number)")
    }
    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }
    final class Counter {
        var value = 0
    }

    func testRecentSelectionKeepsTheNewestCommentsInInputOrderAndClampsTheLimitWhenApplied() {
        let five = (1...5).map { comment($0) }
        XCTAssertEqual(HMCommentSelection.recent.apply(to: five).map(\.id), ["c4", "c5"])
        XCTAssertEqual(HMCommentSelection.recent(limit: 1).apply(to: five).map(\.id), ["c5"])
        XCTAssertEqual(HMCommentSelection.recent(limit: 9).apply(to: five).map(\.id), ["c3", "c4", "c5"]) // Clamped to maximumLimit.
        XCTAssertEqual(HMCommentSelection.recent(limit: 0).apply(to: five).map(\.id), ["c5"]) // A non-empty list gives at least one.
        XCTAssertEqual(HMCommentSelection.recent.apply(to: [comment(1)]).map(\.id), ["c1"])
        XCTAssertTrue(HMCommentSelection.recent.apply(to: [HMSocialComment]()).isEmpty)
        XCTAssertEqual(HMCommentSelection.recent, .recent(limit: 2))
        XCTAssertEqual(HMCommentSelection.recent.rule, "recent")
        XCTAssertEqual(HMCommentSelection.recent.limit, 2)
        XCTAssertEqual(HMCommentSelection.maximumLimit, 3)
        // The same value ranks headless chat messages: oldest first in, input order kept.
        let messages = (1...3).map { HMChatMessage(id: "m\($0)", author: "Fan", text: "Hi", offset: Double($0)) }
        XCTAssertEqual(HMCommentSelection.recent.apply(to: messages).map(\.id), ["m2", "m3"])
    }

    func testSelectionRoundTripsJSONAndQueryItemsAndDegradesUnknownRulesToRecent() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(HMCommentSelection.recent)
        XCTAssertEqual(String(decoding: json, as: UTF8.self), #"{"limit":2,"rule":"recent"}"#)
        XCTAssertEqual(try JSONDecoder().decode(HMCommentSelection.self, from: json), .recent)
        // A rule this SDK does not know keeps its name on the wire and previews as recent.
        let wire = Data(#"{"rule":"topReactions","limit":1,"window":30,"minimum":3}"#.utf8)
        let future = try JSONDecoder().decode(HMCommentSelection.self, from: wire)
        XCTAssertEqual(future.rule, "topReactions")
        XCTAssertEqual(future.limit, 1)
        XCTAssertEqual(future.apply(to: (1...5).map { comment($0) }).map(\.id), ["c5"])
        XCTAssertEqual(String(decoding: try encoder.encode(future), as: UTF8.self), #"{"limit":1,"rule":"topReactions"}"#)
        let items = HMCommentSelection.recent(limit: 1).queryItems
        XCTAssertEqual(items, [URLQueryItem(name: "rule", value: "recent"), URLQueryItem(name: "limit", value: "1")])
        XCTAssertEqual(HMCommentSelection(queryItems: items), .recent(limit: 1))
        XCTAssertEqual(HMCommentSelection(queryItems: []), .recent) // Missing keys take the defaults.
        XCTAssertEqual(HMCommentSelection(queryItems: [URLQueryItem(name: "rule", value: "verifiedOnly")]).rule, "verifiedOnly")
        XCTAssertEqual(HMCommentSelection(queryItems: [URLQueryItem(name: "limit", value: "many")]), .recent)
    }

    func testEngagementAudienceCountAndPinnedCommentArePushedValuesThatInvalidateObservers() {
        let item = HMMediaItem(id: "live", url: URL(string: "https://example.com/live.m3u8")!)
        let source = EngagementTests.ItemSource()
        let engagement = HMEngagement(item: item, timeline: source.timeline(for: item), source: source)
        XCTAssertNil(engagement.audienceCount)
        XCTAssertNil(engagement.pinnedComment)
        let invalidations = Counter()
        let observe = {
            withObservationTracking { _ = engagement.audienceCount; _ = engagement.pinnedComment } onChange: {
                MainActor.assumeIsolated { invalidations.value += 1 }
            }
        }
        observe()
        let revision = engagement.revision
        engagement.updateAudienceCount(1_234) // A pushed value with no timeline offset: the live shape.
        XCTAssertEqual(engagement.audienceCount, 1_234)
        XCTAssertGreaterThan(engagement.revision, revision)
        XCTAssertEqual(invalidations.value, 1)
        observe()
        engagement.updateAudienceCount(-5)
        XCTAssertEqual(engagement.audienceCount, 0) // Negatives clamp like comment counts.
        engagement.updateAudienceCount(nil)
        XCTAssertNil(engagement.audienceCount) // nil hides.
        XCTAssertEqual(invalidations.value, 2)
        let pinned = HMTimelineEvent(id: "pin", offset: 0, kind: .chat, author: "Host", text: "Welcome",
                                     wallTime: Date(timeIntervalSince1970: 10))
        engagement.updatePinnedComment(pinned)
        XCTAssertEqual(engagement.pinnedComment, pinned)
        engagement.updatePinnedComment(HMTimelineEvent(id: "cheer", offset: 0, kind: .reaction, emoji: "🔥"))
        XCTAssertEqual(engagement.pinnedComment, pinned) // Only chat can be pinned.
        engagement.removeMessage(id: "pin")
        XCTAssertNil(engagement.pinnedComment) // Deleting the pinned message unpins it,
        engagement.updatePinnedComment(pinned)
        XCTAssertNil(engagement.pinnedComment) // and a deleted message cannot be pinned again.
        let replacement = HMTimelineEvent(id: "pin-2", offset: 0, kind: .chat, author: "Host", text: "Second half")
        engagement.updatePinnedComment(replacement)
        XCTAssertEqual(engagement.pinnedComment?.id, "pin-2")
        engagement.updatePinnedComment(nil)
        XCTAssertNil(engagement.pinnedComment)
        XCTAssertTrue(engagement.comments(near: 0).isEmpty) // Neither value ever enters the comment list or the timeline.
        XCTAssertTrue(engagement.timeline.events(in: 0...1_000).isEmpty)
    }

    func testAdapterMirrorsPushedAudienceAndPreviewsTheTwoNewestCommentsByDefault() async throws {
        let item = HMMediaItem(id: "item", url: URL(string: "https://example.com/clip.mp4")!)
        let source = EngagementTests.ItemSource()
        source.page = HMCommentPage(comments: (1...5).map { number in
            HMTimelineEvent(id: "c\(number)", offset: Double(number), kind: .chat, author: "Fan \(number)",
                            text: "Comment \(number)", wallTime: Date(timeIntervalSince1970: Double(number)))
        })
        let engagement = HMEngagement(item: item, timeline: source.timeline(for: item), source: source)
        var metadata = HMSocialContent(title: "Moment")
        metadata.viewCount = 1_200
        let adapter = HMEngagementSocialAdapter(engagement: engagement, metadata: metadata)
        XCTAssertNil(adapter.content.audienceCount)
        XCTAssertEqual(adapter.content.viewCount, 1_200) // Recorded views stay host metadata.
        try await engagement.loadComments()
        await settle()
        XCTAssertEqual(adapter.content.comments.map(\.id), ["c1", "c2", "c3", "c4", "c5"])
        XCTAssertEqual(adapter.content.previewComments.map(\.id), ["c4", "c5"])
        engagement.updateAudienceCount(42)
        await settle()
        XCTAssertEqual(adapter.content.audienceCount, 42) // The push invalidates the mapping through revision.
        engagement.updateAudienceCount(nil)
        await settle()
        XCTAssertNil(adapter.content.audienceCount)
        XCTAssertEqual(adapter.content.viewCount, 1_200)
    }

    func testAudienceBadgePrefersWatchingOverViewsAndFormatsCompactly() {
        let locale = Locale(identifier: "en_US_POSIX")
        XCTAssertEqual(HMAudienceBadge.label(audienceCount: 1_234, viewCount: nil, locale: locale),
                       HMAudienceBadge.Label(compact: "1.2K", exact: "1234", unit: .watching))
        XCTAssertEqual(HMAudienceBadge.label(audienceCount: 1_234, viewCount: 9_000, locale: locale)?.unit, .watching)
        XCTAssertEqual(HMAudienceBadge.label(audienceCount: nil, viewCount: 1_200, locale: locale),
                       HMAudienceBadge.Label(compact: "1.2K", exact: "1200", unit: .views))
        XCTAssertEqual(HMAudienceBadge.label(audienceCount: 0, viewCount: 5, locale: locale),
                       HMAudienceBadge.Label(compact: "0", exact: "0", unit: .watching)) // A real zero is data, not absence.
        XCTAssertEqual(HMAudienceBadge.label(audienceCount: 999_950, viewCount: nil, locale: locale)?.compact, "1M")
        XCTAssertEqual(HMAudienceBadge.label(audienceCount: -3, viewCount: nil, locale: locale)?.exact, "0")
        XCTAssertNil(HMAudienceBadge.label(audienceCount: nil, viewCount: nil, locale: locale))
    }

    func testSocialOptionsLeaveSelectionToTheSourceAndPlaceTheBadgeUnderTheTitleByDefault() {
        let options = HMSocialOptions()
        XCTAssertNil(options.commentSelection)
        XCTAssertEqual(options.audienceBadgePlacement, .belowTitle)
        var selecting = options
        selecting.commentSelection = .recent(limit: 1)
        selecting.audienceBadgePlacement = .topLeading
        XCTAssertNotEqual(selecting, options)
        let content = HMSocialContent(title: "Moment", previewComments: [comment(9)], comments: (1...3).map { comment($0) })
        XCTAssertEqual(options.previewCandidates(for: content).map(\.id), ["c9"]) // nil trusts the data source's pick.
        XCTAssertEqual(selecting.previewCandidates(for: content).map(\.id), ["c3"]) // A rule replaces it.
        var counted = HMSocialContent(title: "Moment")
        XCTAssertNil(counted.audienceCount)
        XCTAssertNil(counted.viewCount)
        counted.audienceCount = 7
        XCTAssertEqual(HMSocialContent(title: "Moment", audienceCount: 7), counted)
        _ = HMTheme.default.image(for: .audience)
        XCTAssertEqual(HMTheme.default.audienceSymbol, "eye.fill")
    }
}
#endif
