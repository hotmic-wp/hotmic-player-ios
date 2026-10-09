import Foundation
import Testing
@_spi(Benchmark) @testable import HotMicPlayer

@Suite("Engagement data layer") @MainActor
struct EngagementTests {

    /// Sorted, appendable fixture timeline.
    final class FixtureTimeline: HMStreamTimeline {
        let duration: TimeInterval
        var events: [HMTimelineEvent]
        init(duration: TimeInterval, events: [HMTimelineEvent]) {
            self.duration = duration
            self.events = events.sorted { $0.offset < $1.offset }
        }
        func events(in range: ClosedRange<TimeInterval>) -> [HMTimelineEvent] { events.filter { range.contains($0.offset) } }
        var density: [HMDensityBucket] { [] }
        var markers: [HMTimelineMarker] { [] }
        func append(_ event: HMTimelineEvent) { events.append(event); events.sort { $0.offset < $1.offset } }
    }

    final class Source: HMInteractionSource {
        var supported: HMEngagementCapabilities
        var fails = false
        var sent: [String] = []
        init(_ supported: HMEngagementCapabilities) { self.supported = supported }
        func timeline(for item: HMMediaItem) -> HMStreamTimeline { FixtureTimeline(duration: 1, events: []) }
        func capabilities(for item: HMMediaItem) -> HMEngagementCapabilities { supported }
        func sendChat(_ text: String, for item: HMMediaItem) async throws { try check(); sent.append(text) }
        func react(_ emoji: String, for item: HMMediaItem) async throws { try check() }
        func react(_ emoji: String, toMessage messageID: String, for item: HMMediaItem) async throws { try check() }
        func vote(pollID: String, optionID: String, for item: HMMediaItem) async throws { try check() }
        private func check() throws { if fails { throw URLError(.timedOut) } }
    }

    /// Only the one required method: everything else must fall back to read-only defaults.
    final class LegacySource: HMInteractionSource {
        func timeline(for item: HMMediaItem) -> HMStreamTimeline { FixtureTimeline(duration: 1, events: []) }
    }

    private let item = HMMediaItem(id: "clip", url: URL(fileURLWithPath: "/tmp/clip.mp4"))

    private func chat(_ offset: TimeInterval, _ id: String) -> HMTimelineEvent {
        HMTimelineEvent(id: id, offset: offset, kind: .chat, author: "a-\(id)", text: "t-\(id)", reactions: ["🔥": 2])
    }

    private func poll(opens: TimeInterval = 5, closes: TimeInterval? = 8) -> HMPoll {
        HMPoll(id: "p", question: "Q", options: [.init(id: "a", text: "A", votes: 3), .init(id: "b", text: "B", votes: 1)],
               opensAt: opens, closesAt: closes)
    }

    @Test("Chat is windowed to the playhead, rewinds on scrub, wraps past the timeline and includes pending sends")
    func chatWindowing() async throws {
        let timeline = FixtureTimeline(duration: 30, events: [
            chat(1, "c1"), chat(4, "c4"), chat(6, "c6"), chat(7, "c7"), chat(9, "c9"), chat(12, "c12"),
            HMTimelineEvent(id: "r8", offset: 8, kind: .reaction, emoji: "🔥", magnitude: 5),
            HMTimelineEvent(id: "m10", offset: 10, kind: .marker, text: "Moment", emoji: "🏆")
        ])
        var clock: TimeInterval = 10
        let source = Source(.all)
        let engagement = HMEngagement(item: item, timeline: timeline, source: source, mediaClock: { clock })

        // Last five seconds up to the playhead, oldest first, reactions excluded, capped.
        #expect(engagement.messages(near: 10, lookback: 5).map(\.id) == ["c6", "c7", "c9"])
        #expect(engagement.messages(near: 10, lookback: 5, limit: 2).map(\.id) == ["c7", "c9"])
        #expect(engagement.messages(near: 10, lookback: 5, limit: 0).isEmpty)
        // Scrubbing back replays what was on screen then; nothing from the future leaks in.
        #expect(engagement.messages(near: 4.5, lookback: 5).map(\.id) == ["c1", "c4"])
        #expect(engagement.messages(near: 0, lookback: 5).isEmpty)
        // A media clock past a short timeline wraps rather than going silent.
        #expect(engagement.timelineOffset(forMediaTime: 40) == 10)
        #expect(engagement.messages(near: 40, lookback: 5).map(\.id) == ["c6", "c7", "c9"])
        let first = try #require(engagement.messages(near: 7, lookback: 0).first)
        #expect(first.author == "a-c7" && first.text == "t-c7" && first.reactions == ["🔥": 2] && !first.isOwn)

        // Aggregates folded once at creation.
        #expect(engagement.reactionTotals == ["🔥": 5])
        #expect(engagement.authoredMoments.map(\.id) == ["m10"])

        // The viewer's message lands at the current media time and survives a scrub away and back.
        clock = 11
        try await engagement.sendChat("  mine  ")
        #expect(source.sent == ["mine"])
        let own = try #require(engagement.messages(near: 11, lookback: 1).last)
        #expect(own.text == "mine" && own.isOwn && own.offset == 11 && own.delivery == .sent)
        #expect(engagement.messages(near: 10.9, lookback: 5).allSatisfy { $0.text != "mine" })
        #expect(engagement.messages(near: 12, lookback: 2).map(\.text).contains("mine"))
        // Stream reaction joins the totals at the playhead; the echo is published.
        try await engagement.react("💜")
        #expect(engagement.reactionTotals["💜"] == HMEngagement.viewerReactionWeight)
        #expect(engagement.lastReactionEcho?.emoji == "💜")
        // Source pushes fold in like history.
        engagement.receive(HMTimelineEvent(id: "live", offset: 10.5, kind: .chat, author: "z", text: "hi"))
        #expect(engagement.messages(near: 11, lookback: 1).map(\.id).contains("live"))
        // Message reactions: optimistic, idempotent, and replaced by authoritative totals.
        try await engagement.react("🔥", toMessage: "c9")
        try await engagement.react("🔥", toMessage: "c9")
        var reacted = try #require(engagement.messages(near: 9, lookback: 0).first)
        #expect(reacted.reactions == ["🔥": 3] && reacted.ownReactions == ["🔥"])
        engagement.updateReactions(["🔥": 10, "😂": 1], forMessage: "c9")
        reacted = try #require(engagement.messages(near: 9, lookback: 0).first)
        #expect(reacted.reactions == ["🔥": 10, "😂": 1])
    }

    @Test("Polls appear in their media window, linger with results, and only accept one vote while open")
    func pollWindows() async throws {
        var clock: TimeInterval = 0
        let engagement = HMEngagement(item: item, timeline: FixtureTimeline(duration: 30, events: []), source: Source(.all),
                                      polls: [poll(), HMPoll(id: "late", question: "L", options: [], opensAt: 20)],
                                      mediaClock: { clock })
        #expect(engagement.polls.map(\.id) == ["p", "late"])
        #expect(engagement.polls(at: 4.99).isEmpty)
        #expect(engagement.polls(at: 5).map(\.id) == ["p"])
        #expect(engagement.polls(at: 13.9, resultsLinger: 6).map(\.id) == ["p"])
        #expect(engagement.polls(at: 14, resultsLinger: 6).isEmpty)
        #expect(engagement.polls(at: 25).map(\.id) == ["late"]) // No close: open to the end.
        let p = poll()
        #expect(!p.isOpen(at: 4.9) && p.isOpen(at: 5) && p.isOpen(at: 7.9) && !p.isOpen(at: 8))
        #expect(p.share(of: "a") == 0.75 && p.totalVotes == 4)

        // Voting before or after the window is rejected; inside it is optimistic and single.
        clock = 9
        await #expect(throws: HMEngagementError.pollClosed) { try await engagement.vote(pollID: "p", optionID: "a") }
        clock = 6
        await #expect(throws: HMEngagementError.unknownPoll) { try await engagement.vote(pollID: "p", optionID: "zz") }
        try await engagement.vote(pollID: "p", optionID: "b")
        var voted = try #require(engagement.polls.first)
        #expect(voted.viewerVote == "b" && voted.options[1].votes == 2)
        await #expect(throws: HMEngagementError.alreadyVoted) { try await engagement.vote(pollID: "p", optionID: "a") }
        // The source can close a poll early and update counts.
        var closed = voted; closed.isClosed = true; closed.options[0].votes = 50
        engagement.update(closed)
        voted = try #require(engagement.polls.first)
        #expect(!voted.isOpen(at: 6) && voted.options[0].votes == 50 && voted.viewerVote == "b")
    }

    @Test("Capabilities gate every action; failures roll back optimistic state; legacy sources stay read-only")
    func capabilityGating() async throws {
        let readOnly = HMEngagement(item: item, timeline: FixtureTimeline(duration: 30, events: [chat(1, "c1")]),
                                    source: Source(.readOnly), polls: [poll(opens: 0)], mediaClock: { 2 })
        #expect(readOnly.capabilities == .readOnly && !readOnly.supports(.sendChat))
        await #expect(throws: HMInteractionError.unsupportedAction) { try await readOnly.sendChat("x") }
        await #expect(throws: HMInteractionError.unsupportedAction) { try await readOnly.react("🔥") }
        await #expect(throws: HMInteractionError.unsupportedAction) { try await readOnly.react("🔥", toMessage: "c1") }
        await #expect(throws: HMInteractionError.unsupportedAction) { try await readOnly.vote(pollID: "p", optionID: "a") }
        #expect(readOnly.lastReactionEcho == nil && readOnly.messages(near: 2).map(\.id) == ["c1"])
        #expect(readOnly.polls.first?.viewerVote == nil && readOnly.lastActionError != nil)

        // Partial support: chat only.
        let chatOnly = Source([.sendChat])
        let partial = HMEngagement(item: item, timeline: FixtureTimeline(duration: 30, events: []), source: chatOnly, mediaClock: { 3 })
        #expect(partial.supports(.sendChat) && !partial.supports(.reactToStream) && !partial.supports([.sendChat, .vote]))
        try await partial.sendChat("ok")
        await #expect(throws: HMInteractionError.unsupportedAction) { try await partial.react("🔥") }
        await #expect(throws: HMEngagementError.emptyMessage) { try await partial.sendChat("   ") }
        await #expect(throws: HMEngagementError.messageTooLong) {
            try await partial.sendChat(String(repeating: "x", count: HMEngagement.maximumMessageLength + 1))
        }

        // A failing source withdraws the pending message and restores the vote and message reaction.
        let failing = Source(.all); failing.fails = true
        let rolledBack = HMEngagement(item: item, timeline: FixtureTimeline(duration: 30, events: [chat(1, "c1")]),
                                      source: failing, polls: [poll(opens: 0)], mediaClock: { 2 })
        await #expect(throws: URLError.self) { try await rolledBack.sendChat("lost") }
        await #expect(throws: URLError.self) { try await rolledBack.vote(pollID: "p", optionID: "a") }
        await #expect(throws: URLError.self) { try await rolledBack.react("🔥", toMessage: "c1") }
        #expect(rolledBack.messages(near: 2).map(\.id) == ["c1"])
        #expect(rolledBack.messages(near: 2).first?.reactions == ["🔥": 2])
        #expect(rolledBack.polls.first?.viewerVote == nil && rolledBack.polls.first?.options[0].votes == 3)
        #expect(rolledBack.lastActionError != nil)

        // A 0.3 source that implements only `timeline(for:)` compiles and is read-only with no polls.
        let legacy = LegacySource()
        #expect(legacy.capabilities(for: item) == .readOnly && legacy.polls(for: item).isEmpty)
        let fromLegacy = HMEngagement(item: item, timeline: legacy.timeline(for: item), source: legacy)
        #expect(fromLegacy.capabilities == .readOnly && fromLegacy.polls.isEmpty)
        // The mock grants everything and its poll sits inside the clip.
        let mock = HMMockInteractionSource(latency: .zero)
        #expect(mock.capabilities(for: item) == .all)
        let mockPoll = try #require(mock.polls(for: HMMediaItem(id: "x", url: item.url!, durationHint: 10)).first)
        #expect(abs(mockPoll.opensAt - 2) < 1e-9 && abs((mockPoll.closesAt ?? 0) - 7) < 1e-9 && mockPoll.options.count >= 2)
    }

    /// A partner timeline that keeps the protocol's default, ignoring `append`.
    final class FixedTimeline: HMStreamTimeline {
        let duration: TimeInterval
        let fixed: [HMTimelineEvent]
        init(duration: TimeInterval, events: [HMTimelineEvent]) { self.duration = duration; fixed = events }
        func events(in range: ClosedRange<TimeInterval>) -> [HMTimelineEvent] { fixed.filter { range.contains($0.offset) } }
        var density: [HMDensityBucket] { [] }
        var markers: [HMTimelineMarker] { [] }
    }

    final class EchoingSource: HMInteractionSource {
        var sentIDs: [String] = []
        func timeline(for item: HMMediaItem) -> HMStreamTimeline { FixedTimeline(duration: 30, events: []) }
        func capabilities(for item: HMMediaItem) -> HMEngagementCapabilities { .all }
        func sendChat(_ message: HMChatMessage, for item: HMMediaItem) async throws { sentIDs.append(message.id) }
        func react(_ emoji: String, for item: HMMediaItem) async throws {}
    }

    @Test("The viewer's sent chat and reactions persist on a timeline that ignores append, and echoes don't double them")
    func ownEventsPersist() async throws {
        let source = EchoingSource()
        var clock: TimeInterval = 5
        let engagement = HMEngagement(item: item, timeline: FixedTimeline(duration: 30, events: [chat(4, "c4")]),
                                      source: source, mediaClock: { clock })
        try await engagement.sendChat("still here")
        try await engagement.react("🔥")
        // The source got the client ID, so it can echo with it.
        let id = try #require(source.sentIDs.first)
        #expect(engagement.messages(near: 5, lookback: 2).map(\.text) == ["t-c4", "still here"])
        // Scrub away and back: still there, although the timeline never stored it.
        clock = 1
        #expect(engagement.messages(near: 1, lookback: 2).isEmpty)
        #expect(engagement.messages(near: 6, lookback: 2).map(\.id).contains(id))
        #expect(engagement.reactions(in: 4...6).map(\.emoji) == ["🔥"])
        #expect(engagement.reactionTotals == ["🔥": HMEngagement.viewerReactionWeight])
        // The source echoes the message with the same ID: one copy, and a reaction echo isn't recounted.
        engagement.receive(HMTimelineEvent(id: id, offset: 5, kind: .chat, author: "You", text: "still here"))
        let reaction = try #require(engagement.reactions(in: 4...6).first)
        engagement.receive(reaction)
        #expect(engagement.messages(near: 6, lookback: 2).filter { $0.id == id }.count == 1)
        #expect(engagement.reactionTotals == ["🔥": HMEngagement.viewerReactionWeight])
        #expect(engagement.holdsViewerState)

        // Ownership: a standalone engagement retains its source; a borrowed one does not.
        var temporary: Source? = Source(.all)
        let borrowed = HMEngagement(item: item, timeline: FixedTimeline(duration: 30, events: []), source: temporary,
                                    retainsSource: false)
        weak let released = temporary
        temporary = nil
        #expect(released == nil)
        await #expect(throws: HMInteractionError.unsupportedAction) { try await borrowed.sendChat("gone") }
    }
}

#if canImport(AVFoundation) && !os(macOS)
@Suite("Player-owned engagement") @MainActor
struct PlayerEngagementTests {
    final class CountingSource: HMInteractionSource {
        var loads: [String] = []
        func timeline(for item: HMMediaItem) -> HMStreamTimeline { HMMockTimeline(itemID: item.id, duration: 10) }
        func capabilities(for item: HMMediaItem) -> HMEngagementCapabilities { .all }
        func sendChat(_ text: String, for item: HMMediaItem) async throws {}
        func engagementDidLoad(_ engagement: HMEngagement) { loads.append(engagement.item.id) }
    }
    actor InstantResolver: HMItemResolver {
        func resolve(_ ref: HMMediaItem.Reference) async throws -> HMResolvedItem {
            HMResolvedItem(url: URL(fileURLWithPath: "/tmp/hotmic-040-\(ref.id).mp4"), format: .mp4)
        }
    }

    private func items(_ count: Int) -> [HMMediaItem] {
        (0..<count).map { HMMediaItem(id: "i\($0)", url: URL(fileURLWithPath: "/tmp/hotmic-040-i\($0).mp4")) }
    }

    @Test("No source means no content; engagements are cached, windowed, kept with viewer state and cleared on teardown")
    func lifecycle() async throws {
        var c = HMPlayerConfiguration(poolSize: 1, prefetch: .off, managesAudioSession: false)
        c.resolveAhead = 0
        // Default: an inert source, never demo content.
        let plain = HMPlayer(configuration: c)
        plain.isFeedVisible = false
        plain.replaceAll(items(2))
        let empty = plain.engagement(for: plain.items[0])
        #expect(empty.capabilities == .readOnly && empty.polls.isEmpty && empty.markers.isEmpty && empty.density.isEmpty)
        #expect(empty.messages(near: 5, lookback: 60).isEmpty && empty.reactionTotals.isEmpty)
        #expect(!(plain.timeline(for: plain.items[0]) is HMMockTimeline))
        plain.teardown()

        let source = CountingSource()
        let player = HMPlayer(configuration: c, interactions: source)
        defer { player.teardown() }
        player.isFeedVisible = false
        let list = items(6)
        player.replaceAll(list)
        let first = player.engagement(for: list[0])
        #expect(player.engagement(for: list[0]) === first)
        // Items outside the playlist get one inert engagement, reused, and never reach the source.
        let stranger = HMMediaItem(id: "gone", url: URL(fileURLWithPath: "/tmp/gone.mp4"))
        let inert = player.engagement(for: stranger)
        #expect(player.engagement(for: stranger) === inert && inert.capabilities == .readOnly)
        #expect(source.loads == ["i0"])

        // Far entries are evicted on the next window refresh unless the viewer acted in them.
        let far = player.engagement(for: list[4]), kept = player.engagement(for: list[5])
        try await kept.sendChat("hold on to this")
        player.jump(toID: "i1")
        #expect(player.engagement(for: list[0]) === first) // Previous entry stays for a swipe back.
        #expect(player.engagement(for: list[5]) === kept)
        #expect(player.engagement(for: list[4]) !== far)
        #expect(source.loads.filter { $0 == "i4" }.count == 2)
        // Removing an entry drops its engagement even with viewer state.
        player.remove(ids: ["i5"])
        #expect(player.cachedEngagementCount <= 3)
        player.teardown()
        #expect(player.cachedEngagementCount == 0)
    }

    @Test("A reference's engagement adopts the resolved item")
    func resolvedItem() async throws {
        var c = HMPlayerConfiguration(poolSize: 1, prefetch: .off, managesAudioSession: false, failedItemPolicy: .stay)
        c.resolveAhead = 0
        let source = CountingSource()
        let player = HMPlayer(configuration: c, resolver: InstantResolver(), interactions: source)
        defer { player.teardown() }
        let reference = HMMediaItem.reference("hotmic", id: "ref")
        player.replaceAll([reference])
        let engagement = player.engagement(for: reference)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while engagement.item.url == nil, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(engagement.item.id == reference.id)
        #expect(engagement.item.url?.lastPathComponent == "hotmic-040-ref.mp4")
    }
}
#endif

