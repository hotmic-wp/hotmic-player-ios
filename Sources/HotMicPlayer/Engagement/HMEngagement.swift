import Foundation
import Observation

/// Observable engagement state for one item: chat, polls, reactions and moments,
/// all indexed by the item's media clock, plus the viewer's actions.
///
/// This is the headless layer. `HotMicPlayerUI` renders it, but a partner with its
/// own design reads the same state and calls the same actions. Get one from
/// `HMPlayer.engagement(for:)`; the player keeps it while its item is near the
/// playhead, or while it holds the viewer's own messages, reactions or votes.
///
/// Queries take a media time and return what belongs *at* that time, so scrubbing
/// back replays the conversation exactly as it happened. Every query reads
/// `revision`, so a SwiftUI body that calls one re-renders when the state changes.
@MainActor @Observable public final class HMEngagement {

    /// The item this state belongs to. Updated to the resolved item once a reference resolves,
    /// so the source's actions receive the URL, format and metadata the resolver supplied.
    public private(set) var item: HMMediaItem
    /// The underlying clock-indexed event store.
    @ObservationIgnored public let timeline: HMStreamTimeline
    /// Actions the source supports for this item.
    public let capabilities: HMEngagementCapabilities
    /// Increments on every change. Queries read it so observers invalidate.
    public private(set) var revision = 0
    /// Reaction totals for the whole item, keyed by emoji.
    public private(set) var reactionTotals: [String: Int] = [:]
    /// The viewer's most recent stream reaction, for an immediate on-screen echo.
    public private(set) var lastReactionEcho: HMReactionEcho?
    /// Description of the most recent failed action, cleared by the next successful one.
    public private(set) var lastActionError: String?

    /// Longest chat message accepted, in characters.
    public static let maximumMessageLength = 200
    /// Engagement weight of one viewer reaction on the waveform.
    ///
    /// Heavier than one ambient crowd reaction on purpose: the waveform is scaled
    /// for crowd volume, so a weight of one would be invisible and the tap would
    /// read as doing nothing.
    public static let viewerReactionWeight = 4

    /// Standalone engagements (previews, tests) retain their source, which must outlive the call.
    /// Player-created ones don't: the player owns its source, and the source keeps engagements
    /// weakly (see `engagementDidLoad`), so neither direction forms a cycle.
    @ObservationIgnored private let retainedSource: HMInteractionSource?
    @ObservationIgnored private weak var borrowedSource: HMInteractionSource?
    private var source: HMInteractionSource? { retainedSource ?? borrowedSource }
    @ObservationIgnored private let mediaClock: @MainActor () -> TimeInterval
    private var pollOrder: [String] = []
    private var pollsByID: [String: HMPoll] = [:]
    private var moments: [HMTimelineEvent] = []
    /// Local overlays on source messages: reaction deltas and the viewer's own reactions.
    private var messageReactions: [String: [String: Int]] = [:]
    private var ownMessageReactions: [String: Set<String>] = [:]
    private var ownMessageIDs: Set<String> = []
    private var pendingMessages: [HMChatMessage] = []
    /// The viewer's confirmed chat and stream reactions, by offset. Kept here as well as appended
    /// to the timeline, because a timeline is free to ignore `append` (the protocol default does);
    /// queries merge this list in and de-duplicate by ID, so a source echo can't double them.
    private var ownEvents: [HMTimelineEvent] = []
    private var ownEventIDs: Set<String> = []
    private var votesInFlight: Set<String> = []
    private var votedPolls: Set<String> = []
    @ObservationIgnored private var nextLocalNumber = 0
    @ObservationIgnored private var echoNumber = 0

    /// Creates engagement state over a timeline. `HMPlayer.engagement(for:)` does this for you;
    /// call it directly to drive components without a player, for example in previews.
    /// The engagement retains `source`.
    public convenience init(item: HMMediaItem, timeline: HMStreamTimeline, source: HMInteractionSource?,
                            capabilities: HMEngagementCapabilities? = nil, polls: [HMPoll]? = nil,
                            mediaClock: @escaping @MainActor () -> TimeInterval = { 0 }) {
        self.init(item: item, timeline: timeline, source: source, retainsSource: true, capabilities: capabilities,
                  polls: polls, mediaClock: mediaClock)
    }

    init(item: HMMediaItem, timeline: HMStreamTimeline, source: HMInteractionSource?, retainsSource: Bool,
         capabilities: HMEngagementCapabilities? = nil, polls: [HMPoll]? = nil,
         mediaClock: @escaping @MainActor () -> TimeInterval = { 0 }) {
        self.item = item
        self.timeline = timeline
        self.retainedSource = retainsSource ? source : nil
        self.borrowedSource = source
        self.capabilities = capabilities ?? source?.capabilities(for: item) ?? .readOnly
        self.mediaClock = mediaClock
        for poll in polls ?? source?.polls(for: item) ?? [] { insert(poll) }
        // One full scan at creation; afterwards totals and moments are maintained incrementally.
        for event in timeline.events(in: -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude) { fold(event) }
    }

    // MARK: - Clock

    /// Seconds on the item's timeline, from zero to `duration`.
    public var duration: TimeInterval { timeline.duration }

    /// Maps a media time onto the engagement timeline.
    ///
    /// Identity for VOD whose timeline matches the asset. A media clock that runs
    /// past the timeline (a looping clip whose duration hint is short) wraps, so
    /// the overlay replays rather than falling silent.
    public func timelineOffset(forMediaTime time: TimeInterval) -> TimeInterval {
        guard time.isFinite, time > 0 else { return 0 }
        // A timeline that doesn't know its length can't wrap; keep the media time.
        let span = timeline.duration
        guard span > 0 else { return time }
        return time <= span ? time : time.truncatingRemainder(dividingBy: span)
    }

    /// The item's current media time, as reported by the player.
    public var currentMediaTime: TimeInterval { mediaClock() }

    // MARK: - Queries

    /// Precomputed waveform for the scrubber.
    public var density: [HMDensityBucket] { _ = revision; return timeline.density }
    /// Clustered engagement peaks for the scrubber, each a seek target.
    public var markers: [HMTimelineMarker] { _ = revision; return timeline.markers }
    /// Authored moments (`.marker` events) in media-time order.
    public var authoredMoments: [HMTimelineEvent] { _ = revision; return moments }
    /// Every poll, ordered by opening time.
    public var polls: [HMPoll] { _ = revision; return pollOrder.compactMap { pollsByID[$0] } }

    /// Chat at the playhead: messages from the last `lookback` seconds up to `mediaTime`,
    /// oldest first, at most `limit`. Includes the viewer's messages still being sent.
    public func messages(near mediaTime: TimeInterval, lookback: TimeInterval = 20, limit: Int = 6) -> [HMChatMessage] {
        _ = revision
        guard limit > 0 else { return [] }
        let now = timelineOffset(forMediaTime: mediaTime)
        let window = max(0, now - max(0, lookback))...max(0, now)
        let chat = merged(timeline.events(in: window), own(in: window)).filter { $0.kind == .chat }
        var result = chat.map(message(from:))
        let pending = pendingMessages.filter { window.contains($0.offset) }
        if !pending.isEmpty { result += pending }
        if result.count > 1 { result.sort { $0.offset < $1.offset } }
        return Array(result.suffix(limit))
    }

    /// Stream reactions whose offset falls in a range of the engagement timeline, including the
    /// viewer's own. This is what floating reactions sample as the playhead advances.
    public func reactions(in range: ClosedRange<TimeInterval>) -> [HMTimelineEvent] {
        _ = revision
        return merged(timeline.events(in: range), own(in: range)).filter { $0.kind == .reaction }
    }

    /// Polls on screen at a media time: open ones, then closed ones for `resultsLinger` seconds.
    public func polls(at mediaTime: TimeInterval, resultsLinger: TimeInterval = 6) -> [HMPoll] {
        let now = timelineOffset(forMediaTime: mediaTime)
        return polls.filter { $0.isVisible(at: now, resultsLinger: resultsLinger) }
    }

    /// Normalised waveform height at a media time, from the same buckets the scrubber draws.
    public func intensity(at mediaTime: TimeInterval) -> Double {
        let density = self.density
        guard !density.isEmpty, timeline.duration > 0 else { return 0 }
        let position = min(0.999, max(0, timelineOffset(forMediaTime: mediaTime) / timeline.duration))
        return density[Int(position * Double(density.count))].intensity
    }

    /// Whether the source supports an action.
    public func supports(_ capability: HMEngagementCapabilities) -> Bool { capabilities.isSuperset(of: capability) }

    // MARK: - Viewer actions

    /// Sends a chat message at the current media time (or `mediaTime`).
    ///
    /// The message shows at once as `.sending`, then joins the timeline when the
    /// source accepts it, so it survives a scrub-back like any other message. On
    /// failure it is withdrawn and the error rethrown. Sources must not echo the
    /// viewer's own message back through `receive(_:)`.
    public func sendChat(_ text: String, at mediaTime: TimeInterval? = nil) async throws {
        try require(.sendChat)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw fail(HMEngagementError.emptyMessage) }
        guard trimmed.count <= Self.maximumMessageLength else { throw fail(HMEngagementError.messageTooLong) }
        let offset = timelineOffset(forMediaTime: mediaTime ?? currentMediaTime)
        let id = localID("chat")
        let message = HMChatMessage(id: id, author: "You", text: trimmed, offset: offset, wallTime: Date(),
                                    isOwn: true, delivery: .sending)
        pendingMessages.append(message); ownMessageIDs.insert(id); changed()
        do {
            try await perform { try await $0.sendChat(message, for: self.item) }
        } catch {
            pendingMessages.removeAll { $0.id == id }; ownMessageIDs.remove(id); changed()
            throw fail(error)
        }
        pendingMessages.removeAll { $0.id == id }
        keepOwn(HMTimelineEvent(id: id, offset: offset, kind: .chat, author: message.author,
                                text: trimmed, wallTime: message.wallTime))
        succeeded()
    }

    /// Reacts to the stream at the current media time (or `mediaTime`).
    ///
    /// The echo is published immediately; the reaction joins the timeline and the
    /// waveform once the source accepts it.
    public func react(_ emoji: String, at mediaTime: TimeInterval? = nil) async throws {
        try require(.reactToStream)
        let offset = timelineOffset(forMediaTime: mediaTime ?? currentMediaTime)
        echoNumber += 1
        lastReactionEcho = HMReactionEcho(id: echoNumber, emoji: emoji)
        do {
            try await perform { try await $0.react(emoji, for: self.item) }
        } catch { throw fail(error) }
        let event = HMTimelineEvent(id: localID("reaction"), offset: offset, kind: .reaction, emoji: emoji,
                                    magnitude: Self.viewerReactionWeight)
        keepOwn(event); fold(event)
        succeeded()
    }

    /// Reacts to one chat message. Optimistic; rolled back if the source fails.
    /// Reacting twice with the same emoji does nothing.
    public func react(_ emoji: String, toMessage messageID: String) async throws {
        try require(.reactToMessage)
        guard messageExists(messageID) else { throw fail(HMEngagementError.unknownMessage) }
        guard ownMessageReactions[messageID]?.contains(emoji) != true else { return }
        ownMessageReactions[messageID, default: []].insert(emoji)
        messageReactions[messageID, default: [:]][emoji, default: 0] += 1
        changed()
        do {
            try await perform { try await $0.react(emoji, toMessage: messageID, for: self.item) }
        } catch {
            ownMessageReactions[messageID]?.remove(emoji)
            messageReactions[messageID]?[emoji, default: 1] -= 1
            changed()
            throw fail(error)
        }
        succeeded()
    }

    /// Votes in a poll that is open at the current media time. Optimistic; rolled back on failure.
    public func vote(pollID: String, optionID: String) async throws {
        try require(.vote)
        guard var poll = pollsByID[pollID], let index = poll.options.firstIndex(where: { $0.id == optionID }) else {
            throw fail(HMEngagementError.unknownPoll)
        }
        guard poll.viewerVote == nil, !votesInFlight.contains(pollID) else { throw fail(HMEngagementError.alreadyVoted) }
        guard poll.isOpen(at: timelineOffset(forMediaTime: currentMediaTime)) else { throw fail(HMEngagementError.pollClosed) }
        poll.viewerVote = optionID
        poll.options[index].votes += 1
        pollsByID[pollID] = poll; votesInFlight.insert(pollID); changed()
        do {
            try await perform { try await $0.vote(pollID: pollID, optionID: optionID, for: self.item) }
        } catch {
            votesInFlight.remove(pollID)
            if var current = pollsByID[pollID], current.viewerVote == optionID {
                current.viewerVote = nil
                if let i = current.options.firstIndex(where: { $0.id == optionID }) { current.options[i].votes -= 1 }
                pollsByID[pollID] = current
            }
            changed()
            throw fail(error)
        }
        votesInFlight.remove(pollID); votedPolls.insert(pollID)
        succeeded()
    }

    // MARK: - Source updates

    /// Adds an event from the source, for example a message or reaction arriving over a socket.
    /// It lands on the timeline at its own offset and folds into every aggregate.
    /// An echo of the viewer's own event (same ID) is not counted twice.
    public func receive(_ event: HMTimelineEvent) {
        timeline.append(event)
        if !ownEventIDs.contains(event.id) { fold(event) }
        changed()
    }

    /// Inserts or replaces a poll with the source's authoritative state (counts, closure).
    /// A vote the viewer has in flight is kept until the source confirms or rejects it.
    public func update(_ poll: HMPoll) {
        var poll = poll
        if votesInFlight.contains(poll.id), let local = pollsByID[poll.id]?.viewerVote, poll.viewerVote == nil {
            poll.viewerVote = local
        }
        insert(poll); changed()
    }

    /// Replaces a message's reaction counts with the source's authoritative totals.
    /// The viewer's own reactions are assumed to be included.
    public func updateReactions(_ counts: [String: Int], forMessage messageID: String) {
        let base = timelineEvent(messageID)?.reactions ?? [:]
        var delta: [String: Int] = [:]
        for emoji in Set(base.keys).union(counts.keys) {
            let difference = (counts[emoji] ?? 0) - (base[emoji] ?? 0)
            if difference != 0 { delta[emoji] = difference }
        }
        messageReactions[messageID] = delta; changed()
    }

    // MARK: - Internals

    private func message(from event: HMTimelineEvent) -> HMChatMessage {
        var reactions = event.reactions
        for (emoji, delta) in messageReactions[event.id] ?? [:] {
            let total = (reactions[emoji] ?? 0) + delta
            reactions[emoji] = total > 0 ? total : nil
        }
        let isOwn = ownMessageIDs.contains(event.id)
        return HMChatMessage(id: event.id, author: event.author ?? "Viewer", avatarURL: event.avatarURL,
                             text: event.text ?? "", offset: event.offset, wallTime: event.wallTime,
                             reactions: reactions, ownReactions: ownMessageReactions[event.id] ?? [],
                             isOwn: isOwn)
    }

    private func timelineEvent(_ id: String) -> HMTimelineEvent? {
        if ownEventIDs.contains(id) { return ownEvents.first { $0.id == id } }
        // Message ids carry no offset, so this is a scan; it only runs on an action or a source update.
        return timeline.events(in: -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude).first { $0.id == id }
    }

    private func own(in range: ClosedRange<TimeInterval>) -> [HMTimelineEvent] {
        ownEvents.isEmpty ? [] : ownEvents.filter { range.contains($0.offset) }
    }

    /// Source events first, then own events the source doesn't already have, by ID.
    private func merged(_ source: [HMTimelineEvent], _ own: [HMTimelineEvent]) -> [HMTimelineEvent] {
        guard !own.isEmpty else { return source }
        let seen = Set(source.map(\.id))
        let extra = own.filter { !seen.contains($0.id) }
        return extra.isEmpty ? source : (source + extra).sorted { $0.offset < $1.offset }
    }

    private func keepOwn(_ event: HMTimelineEvent) {
        let index = ownEvents.firstIndex { $0.offset > event.offset } ?? ownEvents.endIndex
        ownEvents.insert(event, at: index); ownEventIDs.insert(event.id)
        timeline.append(event)
    }

    // MARK: - Player support

    /// Whether the viewer has sent, reacted or voted here, or has an action in flight. The player
    /// keeps such engagements when their item leaves the window, so that state isn't lost.
    var holdsViewerState: Bool {
        !ownEvents.isEmpty || !pendingMessages.isEmpty || !votesInFlight.isEmpty || !votedPolls.isEmpty
            || !ownMessageReactions.values.allSatisfy(\.isEmpty)
    }

    /// Adopts the resolved form of the same entry.
    func updateItem(_ resolved: HMMediaItem) {
        guard resolved.id == item.id, resolved != item else { return }
        item = resolved
    }

    private func messageExists(_ id: String) -> Bool { timelineEvent(id)?.kind == .chat }

    private func insert(_ poll: HMPoll) {
        if pollsByID.updateValue(poll, forKey: poll.id) == nil { pollOrder.append(poll.id) }
        pollOrder.sort { (pollsByID[$0]?.opensAt ?? 0) < (pollsByID[$1]?.opensAt ?? 0) }
    }

    private func fold(_ event: HMTimelineEvent) {
        switch event.kind {
        case .reaction:
            if let emoji = event.emoji { reactionTotals[emoji, default: 0] += event.magnitude }
        case .marker:
            let index = moments.firstIndex { $0.offset > event.offset } ?? moments.endIndex
            moments.insert(event, at: index)
        default: break
        }
    }

    private func require(_ capability: HMEngagementCapabilities) throws {
        guard supports(capability), source != nil else { throw fail(HMInteractionError.unsupportedAction) }
    }

    private func perform(_ action: @MainActor (HMInteractionSource) async throws -> Void) async throws {
        guard let source else { throw HMInteractionError.unsupportedAction }
        try await action(source)
    }

    private func localID(_ kind: String) -> String {
        nextLocalNumber += 1
        return "\(item.id)-own-\(kind)-\(nextLocalNumber)-\(UUID().uuidString.prefix(8))"
    }

    private func changed() { revision += 1 }
    private func succeeded() { lastActionError = nil; changed() }
    private func fail(_ error: Error) -> Error {
        lastActionError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return error
    }
}
