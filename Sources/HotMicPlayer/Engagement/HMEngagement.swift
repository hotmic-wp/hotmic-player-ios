import Foundation
import Observation

/// Observable engagement state for one item: chat, polls, reactions and moments,
/// all indexed by the item's media clock, plus the viewer's actions.
///
/// This is the headless layer. `HotMicPlayerUI` renders it, but a partner with its
/// own design reads the same state and calls the same actions. Get one from
/// `HMPlayer.engagement(for:)`; the player keeps it while its item is near the
/// playhead, or while it holds the viewer's own messages, reactions or votes.
/// The player retains bounded deletion records separately, across engagement eviction.
///
/// Queries take a media time and return what belongs *at* that time, so scrubbing
/// back replays the conversation exactly as it happened. Every query reads
/// `revision`, so a SwiftUI body that calls one re-renders when the state changes.
///
/// Access on the main actor.
@MainActor @Observable public final class HMEngagement {

    /// The item this state belongs to. Updated to the resolved item once a reference resolves,
    /// so the source's actions receive the URL, format and metadata the resolver supplied.
    ///
    /// Access on the main actor.
    public private(set) var item: HMMediaItem
    /// The underlying clock-indexed event store.
    ///
    /// Access on the main actor.
    @ObservationIgnored public let timeline: HMStreamTimeline
    /// Actions the source supports for this item.
    ///
    /// Access on the main actor.
    public let capabilities: HMEngagementCapabilities
    /// Increments on every change. Queries read it so observers invalidate.
    ///
    /// Access on the main actor.
    public var revision: Int { localRevision + moderation.revision }
    private var localRevision = 0
    /// Reaction totals for the whole item, keyed by emoji.
    ///
    /// Access on the main actor.
    public var reactionTotals: [String: Int] { _ = revision; return reactionTotalValues }
    private var reactionTotalValues: [String: Int] = [:]
    /// The viewer's most recent stream reaction, for an immediate on-screen echo.
    ///
    /// Access on the main actor.
    public private(set) var lastReactionEcho: HMReactionEcho?
    /// Description of the most recent failed action, cleared by the next successful one.
    ///
    /// Access on the main actor.
    public private(set) var lastActionError: String?

    /// Longest chat message accepted, in characters.
    ///
    /// Access on the main actor.
    public static let maximumMessageLength = 200
    /// Engagement weight of one viewer reaction on the waveform.
    ///
    /// Heavier than one ambient crowd reaction on purpose: the waveform is scaled
    /// for crowd volume, so a weight of one would be invisible and the tap would
    /// read as doing nothing.
    ///
    /// Access on the main actor.
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
    /// Server ID → the local ID the message was shown under while sending, for stable row identity.
    private var clientIDs: [String: String] = [:]
    private var pendingMessages: [HMChatMessage] = []
    /// The viewer's confirmed chat and stream reactions, by offset. Kept here as well as appended
    /// to the timeline, because a timeline is free to ignore `append` (the protocol default does);
    /// queries merge this list in and de-duplicate by ID, so a source echo can't double them.
    private var ownEvents: [HMTimelineEvent] = []
    private var ownEventIDs: Set<String> = []
    /// IDs folded into the aggregates from `receive(_:)`. The timeline may not keep them, and an
    /// echo can arrive before the action that caused it is confirmed.
    @ObservationIgnored private var foldedIDs: Set<String> = []
    @ObservationIgnored private let moderation: HMModerationState
    @ObservationIgnored private var appliedModerationRevision = 0
    @ObservationIgnored private var appliedEventRevision = 0
    @ObservationIgnored private var receivedEvents: [String: HMTimelineEvent] = [:]
    @ObservationIgnored private var foldedReactions: [String: HMTimelineEvent] = [:]
    @ObservationIgnored private var moderatedDensity: [HMDensityBucket]?
    @ObservationIgnored private var moderatedMarkers: [HMTimelineMarker]?
    @ObservationIgnored private var waveformDirty = false
    @ObservationIgnored private var localEventsDirty = true
    @ObservationIgnored private var sortedLocalEvents: [HMTimelineEvent] = []
    private var messageReactionVersions: [String: [String: Int]] = [:]
    private var pollVersions: [String: Int] = [:]
    private var inheritedPollVotes: Set<String> = []
    private var votesInFlight: [String: UUID] = [:]
    private var votedPolls: Set<String> = []
    @ObservationIgnored private var nextLocalNumber = 0
    @ObservationIgnored private var echoNumber = 0
    @ObservationIgnored private var lastReactionEventID: String?

    /// Creates engagement state over a timeline. `HMPlayer.engagement(for:)` does this for you;
    /// call it directly to drive components without a player, for example in previews.
    /// The engagement retains `source`.
    ///
    /// Access on the main actor.
    public convenience init(item: HMMediaItem, timeline: HMStreamTimeline, source: HMInteractionSource?,
                            capabilities: HMEngagementCapabilities? = nil, polls: [HMPoll]? = nil,
                            mediaClock: @escaping @MainActor () -> TimeInterval = { 0 }) {
        self.init(item: item, timeline: timeline, source: source, retainsSource: true, capabilities: capabilities,
                  polls: polls, mediaClock: mediaClock)
    }

    init(item: HMMediaItem, timeline: HMStreamTimeline, source: HMInteractionSource?, retainsSource: Bool,
         capabilities: HMEngagementCapabilities? = nil, polls: [HMPoll]? = nil,
         moderation: HMModerationState? = nil, mediaClock: @escaping @MainActor () -> TimeInterval = { 0 }) {
        self.moderation = moderation ?? HMModerationState()
        self.item = item
        self.timeline = timeline
        self.retainedSource = retainsSource ? source : nil
        self.borrowedSource = source
        self.capabilities = capabilities ?? source?.capabilities(for: item) ?? .readOnly
        self.mediaClock = mediaClock
        for poll in polls ?? source?.polls(for: item) ?? [] where !self.moderation.removesPoll(poll.id) { insert(poll) }
        appliedModerationRevision = self.moderation.revision
        appliedEventRevision = self.moderation.eventRevision
        waveformDirty = self.moderation.hasEventRemovals
        // One full scan at creation; afterwards totals and moments are maintained incrementally.
        for event in timeline.events(in: -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude) {
            if !self.moderation.removesEvent(event.id), foldedIDs.insert(event.id).inserted { fold(event) }
        }
        self.moderation.observe(self)
    }

    // MARK: - Clock

    /// Seconds on the item's timeline, from zero to `duration`.
    ///
    /// Access on the main actor.
    public var duration: TimeInterval { timeline.duration }

    /// Maps a media time onto the engagement timeline.
    ///
    /// Identity for VOD whose timeline matches the asset. A media clock that runs
    /// past the timeline (a looping clip whose duration hint is short) wraps, so
    /// the overlay replays rather than falling silent.
    ///
    /// Access on the main actor.
    public func timelineOffset(forMediaTime time: TimeInterval) -> TimeInterval {
        guard time.isFinite, time > 0 else { return 0 }
        // A timeline that doesn't know its length can't wrap; keep the media time.
        let span = timeline.duration
        guard span > 0 else { return time }
        return time <= span ? time : time.truncatingRemainder(dividingBy: span)
    }

    /// The item's current media time, as reported by the player.
    ///
    /// Access on the main actor.
    public var currentMediaTime: TimeInterval { mediaClock() }

    // MARK: - Queries

    /// Waveform for the scrubber. A dirty moderation projection rebuilds once on the next
    /// density/marker read. Source weighting is kept when its events already exclude deletions;
    /// otherwise surviving events use SDK aggregation with the source's bucket count.
    ///
    /// Access on the main actor.
    public var density: [HMDensityBucket] {
        _ = revision; rebuildWaveformIfNeeded()
        return moderatedDensity ?? timeline.density
    }
    /// Clustered engagement peaks for the scrubber, each a seek target.
    ///
    /// Access on the main actor.
    public var markers: [HMTimelineMarker] {
        _ = revision; rebuildWaveformIfNeeded()
        return moderatedMarkers ?? timeline.markers
    }
    /// Authored moments (`.marker` events) in media-time order.
    ///
    /// Access on the main actor.
    public var authoredMoments: [HMTimelineEvent] { _ = revision; return moments }
    /// Every poll, ordered by opening time.
    ///
    /// Access on the main actor.
    public var polls: [HMPoll] { _ = revision; return pollOrder.compactMap { pollsByID[$0] } }

    /// Chat at the playhead: messages from the last `lookback` seconds up to `mediaTime`,
    /// oldest first, at most `limit`. Includes the viewer's messages still being sent.
    ///
    /// Access on the main actor.
    public func messages(near mediaTime: TimeInterval, lookback: TimeInterval = 20, limit: Int = 6) -> [HMChatMessage] {
        _ = revision; synchronizeModeration()
        guard limit > 0 else { return [] }
        let now = timelineOffset(forMediaTime: mediaTime)
        let window = max(0, now - max(0, lookback))...max(0, now)
        let chat = merged(timeline.events(in: window), own(in: window)).filter { $0.kind == .chat }
        let pending = pendingMessages.filter { window.contains($0.offset) && !moderation.removesEvent($0.id) }
        return Array(mergeSorted(chat.map(message(from:)), pending, offset: { $0.offset }).suffix(limit))
    }

    /// Stream reactions whose offset falls in a range of the engagement timeline, including the
    /// viewer's own. This is what floating reactions sample as the playhead advances.
    ///
    /// Access on the main actor.
    public func reactions(in range: ClosedRange<TimeInterval>) -> [HMTimelineEvent] {
        _ = revision; synchronizeModeration()
        return merged(timeline.events(in: range), own(in: range)).filter { $0.kind == .reaction }
    }

    /// Polls on screen at a media time: open ones, then closed ones for `resultsLinger` seconds.
    ///
    /// Access on the main actor.
    public func polls(at mediaTime: TimeInterval, resultsLinger: TimeInterval = 6) -> [HMPoll] {
        let now = timelineOffset(forMediaTime: mediaTime)
        return polls.filter { $0.isVisible(at: now, resultsLinger: resultsLinger) }
    }

    /// Normalised waveform height at a media time, from the same buckets the scrubber draws.
    ///
    /// Access on the main actor.
    public func intensity(at mediaTime: TimeInterval) -> Double {
        let density = self.density
        guard !density.isEmpty, timeline.duration > 0 else { return 0 }
        let position = min(0.999, max(0, timelineOffset(forMediaTime: mediaTime) / timeline.duration))
        return density[Int(position * Double(density.count))].intensity
    }

    /// Whether the source supports an action.
    ///
    /// Access on the main actor.
    public func supports(_ capability: HMEngagementCapabilities) -> Bool { capabilities.isSuperset(of: capability) }

    // MARK: - Viewer actions

    /// Sends a chat message at the current media time (or `mediaTime`).
    ///
    /// The message shows at once as `.sending` under a local ID. When the source accepts it,
    /// the confirmed event the source returns replaces it (server ID, author, wall time,
    /// counts; the offset stays where it was sent), so later `updateReactions(_:forMessage:)`
    /// calls and echoes by the server ID find it. A source that returns nil keeps the local
    /// ID. On failure the message is withdrawn and the error rethrown.
    ///
    /// Access on the main actor.
    public func sendChat(_ text: String, at mediaTime: TimeInterval? = nil) async throws {
        try require(.sendChat)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw fail(HMEngagementError.emptyMessage) }
        guard trimmed.count <= Self.maximumMessageLength else { throw fail(HMEngagementError.messageTooLong) }
        let offset = timelineOffset(forMediaTime: mediaTime ?? currentMediaTime)
        let id = localID("chat")
        let message = HMChatMessage(id: id, author: "You", text: trimmed, offset: offset, wallTime: Date(),
                                    isOwn: true, delivery: .sending)
        let index = pendingMessages.firstIndex { $0.offset > offset } ?? pendingMessages.endIndex
        pendingMessages.insert(message, at: index); ownMessageIDs.insert(id); changed()
        var confirmed: HMTimelineEvent?
        do {
            confirmed = try await performReturning { try await $0.sendChat(message, for: self.item) }
        } catch {
            pendingMessages.removeAll { $0.id == id }; ownMessageIDs.remove(id); changed()
            throw fail(error)
        }
        pendingMessages.removeAll { $0.id == id }
        // A moderator can delete the local pending ID or the server ID while the send awaits.
        if moderation.removesEvent(id) || confirmed.map({ moderation.removesEvent($0.id) }) == true {
            moderation.removeEvent(id)
            moderation.removeEvent(confirmed?.id ?? id)
            synchronizeModeration()
            ownMessageIDs.remove(id)
            succeeded()
            return
        }
        let event = HMTimelineEvent(id: confirmed?.id ?? id, offset: offset, kind: .chat,
                                    author: confirmed?.author ?? message.author, text: confirmed?.text ?? trimmed,
                                    avatarURL: confirmed?.avatarURL, wallTime: confirmed?.wallTime ?? message.wallTime,
                                    reactions: confirmed?.reactions ?? [:])
        if event.id != id {
            ownMessageIDs.remove(id); ownMessageIDs.insert(event.id)
            clientIDs[event.id] = id
        }
        keepOwn(event)
        succeeded()
    }

    /// Reacts to the stream at the current media time (or `mediaTime`).
    ///
    /// The echo is published immediately; the reaction joins the timeline and the
    /// waveform once the source accepts it, under the ID of the event the source
    /// returns (or a local ID for nil), so an echo by that ID isn't counted twice.
    ///
    /// Access on the main actor.
    public func react(_ emoji: String, at mediaTime: TimeInterval? = nil) async throws {
        try require(.reactToStream)
        let offset = timelineOffset(forMediaTime: mediaTime ?? currentMediaTime)
        echoNumber += 1
        lastReactionEcho = moderation.suppressesAll ? nil : HMReactionEcho(id: echoNumber, emoji: emoji)
        let local = HMTimelineEvent(id: localID("reaction"), offset: offset, kind: .reaction, emoji: emoji,
                                    magnitude: Self.viewerReactionWeight, wallTime: Date())
        var confirmed: HMTimelineEvent?
        do {
            confirmed = try await performReturning { try await $0.react(local, for: self.item) }
        } catch { throw fail(error) }
        // The viewer's weight and offset stay local; the source contributes identity and wall time.
        let event = HMTimelineEvent(id: confirmed?.id ?? local.id, offset: offset, kind: .reaction, emoji: emoji,
                                    magnitude: Self.viewerReactionWeight, wallTime: confirmed?.wallTime ?? local.wallTime)
        guard !moderation.removesEvent(event.id) else { lastReactionEcho = nil; succeeded(); return }
        lastReactionEventID = event.id
        let echoedFirst = knows(event.id)
        keepOwn(event)
        if !echoedFirst { fold(event) }
        succeeded()
    }

    /// Reacts to one chat message. Optimistic; rolled back if the source fails.
    /// Reacting twice with the same emoji does nothing.
    ///
    /// Access on the main actor.
    public func react(_ emoji: String, toMessage messageID: String) async throws {
        try require(.reactToMessage)
        guard messageExists(messageID) else { throw fail(HMEngagementError.unknownMessage) }
        guard ownMessageReactions[messageID]?.contains(emoji) != true else { return }
        ownMessageReactions[messageID, default: []].insert(emoji)
        messageReactions[messageID, default: [:]][emoji, default: 0] += 1
        let version = messageReactionVersions[messageID]?[emoji] ?? 0
        changed()
        do {
            try await perform { try await $0.react(emoji, toMessage: messageID, for: self.item) }
        } catch {
            if !moderation.removesEvent(messageID), (messageReactionVersions[messageID]?[emoji] ?? 0) == version {
                ownMessageReactions[messageID]?.remove(emoji)
                messageReactions[messageID]?[emoji, default: 1] -= 1
                changed()
            }
            throw fail(error)
        }
        succeeded()
    }

    /// Votes in a poll that is open at the current media time. Optimistic; rolled back on failure.
    ///
    /// Access on the main actor.
    public func vote(pollID: String, optionID: String) async throws {
        try require(.vote)
        synchronizeModeration()
        guard var poll = pollsByID[pollID], let index = poll.options.firstIndex(where: { $0.id == optionID }) else {
            throw fail(HMEngagementError.unknownPoll)
        }
        guard poll.viewerVote == nil, votesInFlight[pollID] == nil else { throw fail(HMEngagementError.alreadyVoted) }
        guard poll.isOpen(at: timelineOffset(forMediaTime: currentMediaTime)) else { throw fail(HMEngagementError.pollClosed) }
        poll.viewerVote = optionID
        poll.options[index].votes += 1
        let token = UUID()
        let version = pollVersions[pollID, default: 0]
        inheritedPollVotes.remove(pollID)
        pollsByID[pollID] = poll; votesInFlight[pollID] = token; changed()
        do {
            try await perform { try await $0.vote(pollID: pollID, optionID: optionID, for: self.item) }
        } catch {
            let stillCurrent = votesInFlight[pollID] == token
            if stillCurrent { votesInFlight[pollID] = nil }
            if stillCurrent, pollVersions[pollID, default: 0] == version || inheritedPollVotes.contains(pollID),
               var current = pollsByID[pollID], current.viewerVote == optionID {
                current.viewerVote = nil
                if pollVersions[pollID, default: 0] == version,
                   let i = current.options.firstIndex(where: { $0.id == optionID }) { current.options[i].votes -= 1 }
                pollsByID[pollID] = current
            }
            if stillCurrent { inheritedPollVotes.remove(pollID) }
            changed()
            throw fail(error)
        }
        if votesInFlight[pollID] == token {
            votesInFlight[pollID] = nil
            inheritedPollVotes.remove(pollID)
            if pollsByID[pollID] != nil { votedPolls.insert(pollID) }
        }
        succeeded()
    }

    // MARK: - Source updates

    /// Adds an event from the source, for example a message or reaction arriving over a socket.
    /// It lands on the timeline at its own offset and folds into every aggregate.
    /// An echo of the viewer's own event (same ID) is not counted twice.
    ///
    /// Access on the main actor.
    public func receive(_ event: HMTimelineEvent) {
        synchronizeModeration()
        guard !moderation.removesEvent(event.id), !foldedIDs.contains(event.id), !ownEventIDs.contains(event.id) else { return }
        timeline.append(event)
        // Only retain incoming payloads if the timeline ignored append.
        if !timeline.events(in: event.offset...event.offset).contains(where: { $0.id == event.id }) {
            receivedEvents[event.id] = event
            localEventsDirty = true
        }
        if !ownEventIDs.contains(event.id), foldedIDs.insert(event.id).inserted { fold(event) }
        changed(waveform: true)
    }

    /// Inserts or replaces a poll by ID, including its options, counts, window and known viewer vote.
    /// If the source omits the viewer vote, a vote still in flight is kept when its option still exists.
    /// A removed poll ID is ignored, including after engagement eviction and rebuild by the player.
    ///
    /// Access on the main actor.
    public func upsertPoll(_ poll: HMPoll) {
        synchronizeModeration()
        guard !moderation.removesPoll(poll.id) else { return }
        var poll = poll
        inheritedPollVotes.remove(poll.id)
        if votesInFlight[poll.id] != nil, let local = pollsByID[poll.id]?.viewerVote, poll.viewerVote == nil,
           poll.options.contains(where: { $0.id == local }) {
            poll.viewerVote = local
            inheritedPollVotes.insert(poll.id)
        }
        pollVersions[poll.id, default: 0] += 1
        insert(poll); changed()
    }

    /// Compatibility spelling of `upsertPoll(_:)`.
    ///
    /// Access on the main actor.
    @available(*, deprecated, renamed: "upsertPoll(_:)")
    public func update(_ poll: HMPoll) { upsertPoll(poll) }

    /// Removes a poll and its local vote state, including before the poll arrives. Idempotent.
    /// Later upserts with this ID are ignored; there is no reinstate API. Player-owned removal
    /// records survive engagement eviction until the item leaves the playlist or player teardown.
    ///
    /// Access on the main actor.
    public func removePoll(id: String) {
        guard moderation.removePoll(id) else { return }
        synchronizeModeration(); changed()
    }

    /// Removes incoming, confirmed-own or pending chat by server ID or local row ID.
    /// Idempotent. Late echoes and send confirmations cannot restore a deleted message.
    /// Chat queries and waveform aggregates exclude it even when the timeline is immutable.
    /// The player retains bounded removal records across engagement eviction and rebuild.
    ///
    /// Access on the main actor.
    public func removeMessage(id: String) {
        synchronizeModeration()
        let serverID = clientIDs.first(where: { $0.value == id })?.key ?? id
        let localID = clientIDs[serverID]
        removeEvent(id: serverID)
        if let localID { removeEvent(id: localID) }
        for key in Set([id, serverID] + (localID.map { [$0] } ?? [])) {
            pendingMessages.removeAll { $0.id == key }
            ownMessageIDs.remove(key)
            clientIDs[key] = nil
            messageReactions[key] = nil
            ownMessageReactions[key] = nil
            messageReactionVersions[key] = nil
        }
    }

    /// Subtracts message-reaction counts, clamped at zero. Pass `isOwn` when the deleted
    /// reaction belongs to the viewer, to clear its selection. Deliver each deletion once:
    /// this count-only model has no individual message-reaction IDs to de-duplicate.
    /// Deltas last only for this engagement instance and are lost on eviction. For durable
    /// moderation, deliver authoritative totals through `updateReactions(_:forMessage:)`.
    ///
    /// Access on the main actor.
    public func removeReaction(_ emoji: String, forMessage messageID: String, count: Int = 1, isOwn: Bool = false) {
        guard count > 0, let event = timelineEvent(messageID), event.kind == .chat else { return }
        let remaining = max(0, (message(from: event).reactions[emoji] ?? 0) - count)
        let delta = remaining - ((moderation.reactionCounts[messageID] ?? event.reactions)[emoji] ?? 0)
        messageReactions[messageID, default: [:]][emoji] = delta == 0 ? nil : delta
        messageReactionVersions[messageID, default: [:]][emoji, default: 0] += 1
        if isOwn || remaining == 0 { ownMessageReactions[messageID]?.remove(emoji) }
        changed()
    }

    /// Removes a stream-reaction event by ID, including its total and waveform contribution.
    /// Idempotent; late echoes and confirmations with this ID are ignored. Player-owned
    /// deletion records survive engagement eviction and rebuild.
    ///
    /// Access on the main actor.
    public func removeReaction(id: String) {
        removeEvent(id: id)
        if lastReactionEventID == id { lastReactionEcho = nil; lastReactionEventID = nil }
    }

    /// Replaces a message's reaction counts with the source's authoritative totals.
    /// The viewer's own reactions are assumed to be included. Prefer this method when the
    /// source has totals; they survive engagement eviction for the playlist item's lifetime.
    /// Counts are clamped at zero and share the bounded player-owned moderation budget.
    /// `removeReaction(_:forMessage:count:isOwn:)` applies instance-local deletion deltas.
    ///
    /// Access on the main actor.
    public func updateReactions(_ counts: [String: Int], forMessage messageID: String) {
        synchronizeModeration()
        guard !moderation.removesEvent(messageID) else { return }
        moderation.updateReactions(counts, for: messageID)
        changed()
    }

    // MARK: - Internals

    private func message(from event: HMTimelineEvent) -> HMChatMessage {
        var reactions = moderation.reactionCounts[event.id] ?? event.reactions
        for (emoji, delta) in messageReactions[event.id] ?? [:] {
            let total = (reactions[emoji] ?? 0) + delta
            reactions[emoji] = total > 0 ? total : nil
        }
        let isOwn = ownMessageIDs.contains(event.id)
        return HMChatMessage(id: event.id, author: event.author ?? "Viewer", avatarURL: event.avatarURL,
                             text: event.text ?? "", offset: event.offset, wallTime: event.wallTime,
                             reactions: reactions, ownReactions: ownMessageReactions[event.id] ?? [],
                             isOwn: isOwn, clientID: clientIDs[event.id] ?? (isOwn ? event.id : nil))
    }

    private func timelineEvent(_ id: String) -> HMTimelineEvent? {
        synchronizeModeration()
        guard !moderation.removesEvent(id) else { return nil }
        if ownEventIDs.contains(id) { return ownEvents.first { $0.id == id } }
        // Message ids carry no offset, so this is a scan; it only runs on an action or a source update.
        return timeline.events(in: -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude).first { $0.id == id }
            ?? receivedEvents[id]
    }

    private func own(in range: ClosedRange<TimeInterval>) -> [HMTimelineEvent] {
        if localEventsDirty {
            sortedLocalEvents = (ownEvents + receivedEvents.values).sorted { $0.offset < $1.offset }
            localEventsDirty = false
        }
        return sortedLocalEvents.filter { range.contains($0.offset) }
    }

    /// Linear merge; local events sort only after mutation. Unsorted partner windows are
    /// normalized only when needed; the ordinary sorted timeline path never sorts per tick.
    private func merged(_ source: [HMTimelineEvent], _ own: [HMTimelineEvent]) -> [HMTimelineEvent] {
        let ordered = zip(source, source.dropFirst()).allSatisfy { $0.offset <= $1.offset }
            ? source : source.sorted { $0.offset < $1.offset }
        return mergeSorted(ordered, own, offset: { $0.offset }).filter { !moderation.removesEvent($0.id) }
    }

    private func mergeSorted<Element: Identifiable>(_ source: [Element], _ local: [Element],
                                                    offset: (Element) -> TimeInterval) -> [Element] {
        var seen = Set<Element.ID>()
        let left = source.filter { seen.insert($0.id).inserted }
        let right = local.filter { seen.insert($0.id).inserted }
        var result: [Element] = []
        result.reserveCapacity(left.count + right.count)
        var i = 0, j = 0
        while i < left.count && j < right.count {
            if offset(left[i]) <= offset(right[j]) { result.append(left[i]); i += 1 }
            else { result.append(right[j]); j += 1 }
        }
        result.append(contentsOf: left[i...]); result.append(contentsOf: right[j...])
        return result
    }

    /// Whether an event with this ID is already known, for example because its echo arrived
    /// before the source confirmed it. Scans the timeline, so only called on an action.
    private func knows(_ id: String) -> Bool {
        ownEventIDs.contains(id) || foldedIDs.contains(id)
            || timeline.events(in: -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude).contains { $0.id == id }
    }

    private func keepOwn(_ event: HMTimelineEvent) {
        guard !moderation.removesEvent(event.id), !ownEventIDs.contains(event.id) else { return }
        let appended = !knows(event.id)
        let index = ownEvents.firstIndex { $0.offset > event.offset } ?? ownEvents.endIndex
        ownEvents.insert(event, at: index); ownEventIDs.insert(event.id)
        localEventsDirty = true; waveformDirty = moderation.hasEventRemovals
        if appended { timeline.append(event) }
    }

    // MARK: - Player support

    /// Whether the viewer has sent, reacted or voted here, or has an action in flight. The player
    /// keeps such engagements when their item leaves the window, so that state isn't lost.
    var holdsViewerState: Bool {
        return !ownEvents.isEmpty || !pendingMessages.isEmpty || !votesInFlight.isEmpty || !votedPolls.isEmpty
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
            if let emoji = event.emoji {
                foldedReactions[event.id] = event
                reactionTotalValues[emoji, default: 0] += event.magnitude
            }
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

    private func performReturning<T>(_ action: @MainActor (HMInteractionSource) async throws -> T) async throws -> T {
        guard let source else { throw HMInteractionError.unsupportedAction }
        return try await action(source)
    }

    private func localID(_ kind: String) -> String {
        nextLocalNumber += 1
        return "\(item.id)-own-\(kind)-\(nextLocalNumber)-\(UUID().uuidString.prefix(8))"
    }

    private func removeEvent(id: String) {
        guard moderation.removeEvent(id) else { return }
        synchronizeModeration(); changed()
    }

    // Invoked synchronously by shared records on mutation, never by public queries.
    func synchronizeModeration(reactionsFor messageID: String? = nil) {
        if let messageID {
            let keys = Set(messageReactions[messageID]?.keys.map { $0 } ?? [])
                .union(moderation.reactionCounts[messageID]?.keys.map { $0 } ?? [])
                .union(ownMessageReactions[messageID] ?? [])
            for emoji in keys { messageReactionVersions[messageID, default: [:]][emoji, default: 0] += 1 }
            messageReactions[messageID] = nil
        }
        guard appliedModerationRevision != moderation.revision else { return }
        appliedModerationRevision = moderation.revision
        if appliedEventRevision != moderation.eventRevision {
            appliedEventRevision = moderation.eventRevision
            waveformDirty = true; localEventsDirty = true
            sortedLocalEvents.removeAll()
            ownEvents.removeAll { moderation.removesEvent($0.id) }
            ownEventIDs = ownEventIDs.filter { !moderation.removesEvent($0) }
            pendingMessages.removeAll { moderation.removesEvent($0.id) }
            ownMessageIDs = ownMessageIDs.filter { !moderation.removesEvent($0) }
            receivedEvents = receivedEvents.filter { !moderation.removesEvent($0.key) }
            foldedIDs = foldedIDs.filter { !moderation.removesEvent($0) }
            moments.removeAll { moderation.removesEvent($0.id) }
            clientIDs = clientIDs.filter { !moderation.removesEvent($0.key) && !moderation.removesEvent($0.value) }
            messageReactions = messageReactions.filter { !moderation.removesEvent($0.key) }
            ownMessageReactions = ownMessageReactions.filter { !moderation.removesEvent($0.key) }
            messageReactionVersions = messageReactionVersions.filter { !moderation.removesEvent($0.key) }
            foldedReactions = foldedReactions.filter { !moderation.removesEvent($0.key) }
            if moderation.suppressesAll { lastReactionEcho = nil; lastReactionEventID = nil }
            reactionTotalValues = [:]
            for event in foldedReactions.values {
                if let emoji = event.emoji { reactionTotalValues[emoji, default: 0] += event.magnitude }
            }
        }
        pollsByID = pollsByID.filter { !moderation.removesPoll($0.key) }
        pollOrder.removeAll { moderation.removesPoll($0) }
        votesInFlight = votesInFlight.filter { !moderation.removesPoll($0.key) }
        votedPolls = votedPolls.filter { !moderation.removesPoll($0) }
        inheritedPollVotes = inheritedPollVotes.filter { !moderation.removesPoll($0) }
        pollVersions = pollVersions.filter { !moderation.removesPoll($0.key) }
    }

    private func rebuildWaveformIfNeeded() {
        guard waveformDirty else { return }
        waveformDirty = false
        if moderation.suppressesAll { moderatedDensity = []; moderatedMarkers = []; return }
        let all = -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude
        let source = timeline.events(in: all)
        // Keep the source's density/weighting if it has already removed these events, or
        // only a pending/non-appended event was removed. Arbitrary source weighting cannot
        // be inverted from normalized buckets; otherwise fall back to SDK aggregation.
        guard source.contains(where: { moderation.removesEvent($0.id) }) else {
            moderatedDensity = nil; moderatedMarkers = nil
            return
        }
        let events = merged(source, own(in: all)).map { foldedReactions[$0.id] ?? $0 }
        let bucketCount = timeline.density.count
        (moderatedDensity, moderatedMarkers) = HMTimelineAggregation.build(
            events: events, duration: duration, bucketCount: bucketCount == 0 ? 60 : bucketCount)
    }

    private func changed(waveform: Bool = false) {
        if waveform && moderation.hasEventRemovals { waveformDirty = true }
        localRevision += 1
    }
    private func succeeded() { lastActionError = nil; changed() }
    private func fail(_ error: Error) -> Error {
        lastActionError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return error
    }
}
