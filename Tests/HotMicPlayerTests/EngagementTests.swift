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
        var density: [HMDensityBucket] { HMTimelineAggregation.build(events: events, duration: duration, bucketCount: 60).0 }
        var markers: [HMTimelineMarker] { HMTimelineAggregation.build(events: events, duration: duration, bucketCount: 60).1 }
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

    /// Confirms with server IDs, like HotMicCore's sendChatMessage. Optionally echoes a reaction
    /// through `receive(_:)` before confirming, to race the confirmation.
    final class ServerSource: HMInteractionSource {
        var sentIDs: [String] = []
        weak var engagement: HMEngagement?
        var echoReactionFirst = false
        var reactions = 0
        var confirmsChat = true
        var beforeChatConfirmation: ((HMChatMessage) -> Void)?
        var beforeReactionConfirmation: ((HMTimelineEvent) -> Void)?
        var beforeVoteConfirmation: (() -> Void)?
        var beforeMessageReactionConfirmation: (() -> Void)?
        var failsVote = false
        var failsMessageReaction = false
        func react(_ emoji: String, toMessage messageID: String, for item: HMMediaItem) async throws {
            beforeMessageReactionConfirmation?()
            if failsMessageReaction { throw URLError(.timedOut) }
        }
        func vote(pollID: String, optionID: String, for item: HMMediaItem) async throws {
            beforeVoteConfirmation?()
            if failsVote { throw URLError(.timedOut) }
        }
        func timeline(for item: HMMediaItem) -> HMStreamTimeline { FixedTimeline(duration: 30, events: []) }
        func capabilities(for item: HMMediaItem) -> HMEngagementCapabilities { .all }
        func sendChat(_ message: HMChatMessage, for item: HMMediaItem) async throws -> HMTimelineEvent? {
            sentIDs.append(message.id)
            beforeChatConfirmation?(message)
            if !confirmsChat { return nil }
            return HMTimelineEvent(id: "srv-\(sentIDs.count)", offset: 999, kind: .chat, author: "mara_v", text: message.text,
                                   wallTime: Date(timeIntervalSince1970: 1), reactions: ["💜": 1])
        }
        func react(_ reaction: HMTimelineEvent, for item: HMMediaItem) async throws -> HMTimelineEvent? {
            reactions += 1
            let confirmed = HMTimelineEvent(id: "srv-rx-\(reactions)", offset: reaction.offset, kind: .reaction,
                                            emoji: reaction.emoji, magnitude: 1)
            if echoReactionFirst { engagement?.receive(confirmed) }
            beforeReactionConfirmation?(confirmed)
            return confirmed
        }
    }

    @Test("Moderation removes every storage form and upserts polls without reviving deleted state",
          arguments: ["history", "incoming", "own-server", "own-row", "own-local", "pending-local", "pending-server",
                      "stream-history", "stream-own", "stream-inflight", "message-reaction-same", "message-reaction-other",
                      "poll", "poll-inflight", "poll-replaced", "poll-inflight-update", "poll-source-vote"])
    func moderationSemantics(_ scenario: String) async throws {
        for appendable in [false, true] {
            let history = scenario == "history" ? [chat(5, "history")] : scenario == "stream-history"
                ? [HMTimelineEvent(id: "stream", offset: 5, kind: .reaction, emoji: "🔥", magnitude: 8)] : []
            let timeline: HMStreamTimeline = appendable
                ? FixtureTimeline(duration: 30, events: history) : FixedTimeline(duration: 30, events: history)
            let source = ServerSource()
            let engagement = HMEngagement(item: item, timeline: timeline, source: source, mediaClock: { 5 })
            source.engagement = engagement
            switch scenario {
            case "history", "incoming", "own-server", "own-row", "own-local":
                var id = "history"
                if scenario == "incoming" {
                    id = "incoming"
                    engagement.receive(chat(5, id))
                    engagement.receive(chat(5, id))
                } else if scenario.hasPrefix("own-") {
                    source.confirmsChat = scenario != "own-local"
                    try await engagement.sendChat("mine")
                    id = scenario == "own-local" ? try #require(source.sentIDs.first) : "srv-1"
                }
                #expect(engagement.messages(near: 5).count == 1)
                // Delete exactly one count, including viewer selection, then clamp at zero.
                engagement.updateReactions(["🔥": 3], forMessage: id)
                try await engagement.react("🔥", toMessage: id)
                engagement.removeReaction("🔥", forMessage: id, isOwn: true)
                #expect(engagement.messages(near: 5).first?.reactions == ["🔥": 3])
                #expect(engagement.messages(near: 5).first?.ownReactions.isEmpty == true)
                engagement.removeReaction("🔥", forMessage: id, count: 99)
                #expect(engagement.messages(near: 5).first?.reactions.isEmpty == true)
                let deletionID = scenario == "own-row" ? try #require(source.sentIDs.first) : id
                engagement.removeMessage(id: deletionID)
                let revision = engagement.revision
                engagement.removeMessage(id: deletionID)
                #expect(engagement.revision == revision)
                engagement.receive(chat(5, id)) // A late echo cannot revive it.
                engagement.updateReactions(["🔥": 9], forMessage: id)
                #expect(engagement.messages(near: 5).isEmpty)
                #expect(engagement.messages(near: 6, lookback: 30).isEmpty)
                #expect(engagement.density.allSatisfy { $0.eventCount == 0 && $0.intensity == 0 })
                #expect(engagement.markers.isEmpty && !engagement.holdsViewerState)
                await #expect(throws: HMEngagementError.unknownMessage) { try await engagement.react("🔥", toMessage: id) }
            case "pending-local", "pending-server":
                source.beforeChatConfirmation = { message in
                    #expect(engagement.messages(near: 5).first?.delivery == .sending)
                    engagement.removeMessage(id: scenario == "pending-local" ? message.id : "srv-1")
                    if scenario == "pending-local" { #expect(engagement.messages(near: 5).isEmpty) }
                }
                try await engagement.sendChat("moderated while sending")
                engagement.receive(chat(5, "srv-1"))
                #expect(engagement.messages(near: 5).isEmpty && !engagement.holdsViewerState)
                #expect(engagement.density.allSatisfy { $0.eventCount == 0 })
            case "stream-history", "stream-own", "stream-inflight":
                var id = "stream"
                if scenario != "stream-history" {
                    id = "srv-rx-1"
                    if scenario == "stream-inflight" {
                        source.echoReactionFirst = true
                        source.beforeReactionConfirmation = { event in engagement.removeReaction(id: event.id) }
                    }
                    try await engagement.react("🔥")
                }
                if scenario != "stream-inflight" { #expect((engagement.reactionTotals["🔥"] ?? 0) > 0) }
                engagement.removeReaction(id: id)
                let revision = engagement.revision
                engagement.removeReaction(id: id)
                #expect(engagement.revision == revision)
                engagement.receive(HMTimelineEvent(id: id, offset: 5, kind: .reaction, emoji: "🔥"))
                #expect(engagement.reactionTotals.isEmpty && engagement.reactions(in: 0...30).isEmpty)
                #expect(engagement.density.allSatisfy { $0.eventCount == 0 && $0.intensity == 0 })
                #expect(engagement.markers.isEmpty && !engagement.holdsViewerState)
            case "message-reaction-same", "message-reaction-other":
                engagement.receive(chat(5, "message"))
                source.failsMessageReaction = true
                source.beforeMessageReactionConfirmation = {
                    engagement.removeReaction(scenario == "message-reaction-same" ? "💜" : "🔥",
                                              forMessage: "message", isOwn: scenario == "message-reaction-same")
                }
                await #expect(throws: URLError.self) { try await engagement.react("💜", toMessage: "message") }
                #expect(engagement.messages(near: 5).first?.reactions == ["🔥": scenario == "message-reaction-same" ? 2 : 1])
                #expect(engagement.messages(near: 5).first?.ownReactions.isEmpty == true)
            default:
                engagement.upsertPoll(poll(opens: 0, closes: 8))
                engagement.upsertPoll(HMPoll(id: "early", question: "Earlier", options: [], opensAt: 1))
                let replacement = HMPoll(id: "p", question: "Replacement", options: [.init(id: "new", text: "New", votes: 12)],
                                         viewerVote: "new", opensAt: 3, closesAt: 6, isClosed: true)
                engagement.upsertPoll(replacement)
                #expect(engagement.polls.map(\.id) == ["early", "p"])
                #expect(engagement.polls.last == replacement)
                #expect(engagement.polls(at: 2).map(\.id) == ["early"])
                engagement.update(poll(opens: 0, closes: 8)) // Compatibility alias also replaces.
                #expect(engagement.polls.first?.options.count == 2 && engagement.polls.first?.viewerVote == nil)
                if scenario == "poll-inflight" {
                    source.beforeVoteConfirmation = { engagement.removePoll(id: "p") }
                    try await engagement.vote(pollID: "p", optionID: "a")
                } else if scenario == "poll-replaced" {
                    source.failsVote = true
                    source.beforeVoteConfirmation = {
                        engagement.removePoll(id: "p")
                        engagement.upsertPoll(replacement)
                    }
                    await #expect(throws: URLError.self) { try await engagement.vote(pollID: "p", optionID: "a") }
                    #expect(engagement.polls.last == replacement)
                } else if scenario == "poll-inflight-update" || scenario == "poll-source-vote" {
                    source.failsVote = true
                    source.beforeVoteConfirmation = {
                        var authoritative = poll(opens: 0, closes: 8)
                        if scenario == "poll-source-vote" { authoritative.viewerVote = "a" }
                        engagement.upsertPoll(authoritative)
                        #expect(engagement.polls.first?.viewerVote == "a")
                    }
                    await #expect(throws: URLError.self) { try await engagement.vote(pollID: "p", optionID: "a") }
                    #expect(engagement.polls.first?.viewerVote == (scenario == "poll-source-vote" ? "a" : nil))
                    #expect(engagement.polls.first?.options.first?.votes == 3)
                }
                engagement.removePoll(id: "p")
                let revision = engagement.revision
                engagement.removePoll(id: "p")
                #expect(engagement.revision == revision)
                #expect(engagement.polls.map(\.id) == ["early"] && !engagement.holdsViewerState)
                engagement.upsertPoll(replacement)
                #expect(engagement.polls.last == replacement)
            }
        }
    }

    @Test("Sent chat and reactions persist on a timeline that ignores append, adopt server IDs, and echoes don't double them")
    func ownEventsPersist() async throws {
        let source = ServerSource()
        var clock: TimeInterval = 5
        let engagement = HMEngagement(item: item, timeline: FixedTimeline(duration: 30, events: [chat(4, "c4")]),
                                      source: source, mediaClock: { clock })
        source.engagement = engagement
        try await engagement.sendChat("still here")
        try await engagement.react("🔥")
        // The confirmed server message replaces the local one, at the offset it was sent.
        let localID = try #require(source.sentIDs.first)
        let mine = try #require(engagement.messages(near: 5, lookback: 2).last)
        #expect(mine.id == "srv-1" && mine.offset == 5 && mine.author == "mara_v" && mine.isOwn)
        #expect(mine.wallTime == Date(timeIntervalSince1970: 1) && mine.reactions == ["💜": 1])
        #expect(mine.clientID == localID && mine.rowID == localID && mine.delivery == .sent)
        #expect(engagement.messages(near: 6, lookback: 30).allSatisfy { $0.id != localID })
        // Scrub away and back: still there, although the timeline never stored it.
        clock = 1
        #expect(engagement.messages(near: 1, lookback: 2).isEmpty)
        #expect(engagement.messages(near: 6, lookback: 2).map(\.id) == ["c4", "srv-1"])
        #expect(engagement.reactions(in: 4...6).map(\.id) == ["srv-rx-1"])
        #expect(engagement.reactionTotals == ["🔥": HMEngagement.viewerReactionWeight])
        // Server updates by the server ID find the message; echoes by it show and count once.
        engagement.updateReactions(["💜": 7], forMessage: "srv-1")
        #expect(engagement.messages(near: 6, lookback: 2).last?.reactions == ["💜": 7])
        engagement.receive(HMTimelineEvent(id: "srv-1", offset: 5, kind: .chat, author: "mara_v", text: "still here"))
        engagement.receive(HMTimelineEvent(id: "srv-rx-1", offset: 5, kind: .reaction, emoji: "🔥", magnitude: 1))
        #expect(engagement.messages(near: 6, lookback: 2).filter { $0.text == "still here" }.count == 1)
        #expect(engagement.reactions(in: 4...6).count == 1)
        #expect(engagement.reactionTotals == ["🔥": HMEngagement.viewerReactionWeight])
        // An echo that arrives before the confirmation isn't counted twice either.
        source.echoReactionFirst = true
        clock = 5
        try await engagement.react("🔥")
        #expect(engagement.reactions(in: 4...6).map(\.id) == ["srv-rx-1", "srv-rx-2"])
        // The echo was folded first, with the server's weight; the confirmation doesn't add the local one.
        #expect(engagement.reactionTotals == ["🔥": HMEngagement.viewerReactionWeight + 1])
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
        var timelineCalls: [String] = []
        func timeline(for item: HMMediaItem) -> HMStreamTimeline {
            timelineCalls.append(item.id)
            return HMMockTimeline(itemID: item.id, duration: 10)
        }
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
        #expect(player.timeline(for: stranger) === inert.timeline)
        #expect(source.loads == ["i0"] && !source.timelineCalls.contains("gone"))

        // Far entries are evicted on the next window refresh unless the viewer acted in them.
        let far = player.engagement(for: list[4]), kept = player.engagement(for: list[5])
        let farTimeline = player.timeline(for: list[4]), lone = player.timeline(for: list[3])
        #expect(far.timeline === farTimeline)
        try await kept.sendChat("hold on to this")
        player.jump(toID: "i1")
        // Timelines follow the same rule: evicted outside the window unless their engagement is kept.
        #expect(player.timeline(for: list[3]) !== lone)
        #expect(player.timeline(for: list[5]) === kept.timeline)
        #expect(player.engagement(for: list[0]) === first) // Previous entry stays for a swipe back.
        #expect(player.engagement(for: list[5]) === kept)
        #expect(player.engagement(for: list[4]) !== far && player.timeline(for: list[4]) !== farTimeline)
        #expect(source.loads.filter { $0 == "i4" }.count == 2)
        // Removing an entry drops its engagement even with viewer state.
        player.remove(ids: ["i5"])
        #expect(player.cachedEngagementCount <= 3)
        player.teardown()
        #expect(player.cachedEngagementCount == 0 && player.cachedTimelineCount == 0)
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
