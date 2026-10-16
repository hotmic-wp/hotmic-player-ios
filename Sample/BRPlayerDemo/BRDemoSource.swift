import Foundation
import HotMicPlayer

/// The demo's synthetic B/R crowd: comments, Fire and comment counts, and a viewer count per clip,
/// read from the seeded files in `Content/`. No network; the same comments arrive in the same order
/// every run. Two comment clocks:
/// - `.wall` (default): earlier comments load as the item's comment history, then new ones trickle
///   in every few seconds while the clip is current, so every clip looks live.
/// - `.media`: every comment sits on the clip's media timeline and replays with the playhead,
///   wrapping when the clip loops (VOD replay through `HMEngagement`).
/// Launch with `-BRCommentClock media` to switch.
@MainActor final class BRDemoSource: HMInteractionSource {
    enum CommentClock: String {
        case wall, media
        /// `-BRCommentClock media` on the launch arguments, else `.wall`.
        static var launchSetting: CommentClock {
            UserDefaults.standard.string(forKey: "BRCommentClock").flatMap(CommentClock.init(rawValue:)) ?? .wall
        }
    }
    let clock: CommentClock
    /// Simulated round trip for viewer actions and comment pages.
    var latency: Duration = .milliseconds(150)
    /// Latest synthetic viewer count per item ID, set while the item is current.
    private(set) var audience: [String: Int] = [:]
    /// Called with each new viewer count; the audience badge (ticket 04) subscribes here.
    var audienceChanged: (_ itemID: String, _ viewers: Int) -> Void = { _, _ in }

    private let catalog: BRDemoCatalog
    private let launchDate = Date()
    private var files: [String: BRDemoComments] = [:]
    private var engagements: [String: WeakEngagement] = [:]
    private var fires: [String: HMItemReactionSummary] = [:]
    private var commentCounts: [String: Int] = [:]
    private var progress: [String: Progress] = [:]
    private var ticker: Task<Void, Never>?
    private var tickingID: String?

    /// How far an item's trickle and viewer walk have got, so swiping back resumes rather than repeats.
    private struct Progress {
        var trickled = 0
        var tick = 0
        var untilComment: Double?
        var untilTick: Double?
    }

    init(catalog: BRDemoCatalog = BRDemoContent.catalog, clock: CommentClock = .launchSetting) {
        self.catalog = catalog; self.clock = clock
    }

    // MARK: HMInteractionSource

    func timeline(for item: HMMediaItem) -> HMStreamTimeline {
        let duration = item.durationHint ?? 0
        guard clock == .media, let file = commentsFile(for: item.id) else { return BRDemoTimeline(duration: duration, events: []) }
        return BRDemoTimeline(duration: duration, events: file.rows.map { $0.event(wallTime: nil) })
    }
    func capabilities(for item: HMMediaItem) -> HMEngagementCapabilities {
        // Paged item comments switch media-clock replay off, so only the wall clock offers them.
        clock == .wall ? [.sendChat, .toggleReaction, .loadComments] : [.sendChat, .toggleReaction]
    }
    func engagementDidLoad(_ engagement: HMEngagement) {
        let id = engagement.item.id
        engagements[id] = WeakEngagement(engagement)
        guard catalog.clip(forItemID: id) != nil else { return }
        engagement.updateReactionSummary(fire(for: id), for: "🔥")
        engagement.updateCommentCount(commentCount(for: id))
        if let viewers = audience[id] { engagement.updateAudienceCount(viewers) }
    }
    func didBecomeCurrent(_ item: HMMediaItem) { startTicker(for: item.id) }
    func didLeave(_ item: HMMediaItem) {
        if tickingID == item.id { ticker?.cancel(); ticker = nil; tickingID = nil }
    }
    // GET comments, newest page first, 20 per page; the cursor is the oldest row's ID.
    func comments(for item: HMMediaItem, before cursor: String?) async throws -> HMCommentPage {
        try await Task.sleep(for: latency)
        guard let file = commentsFile(for: item.id) else { return HMCommentPage(comments: [], totalCount: nil) }
        let all = file.history.map { $0.event(wallTime: launchDate.addingTimeInterval(-($0.postedAgo ?? 0))) }
        var end = all.count
        if let cursor {
            guard let index = all.firstIndex(where: { $0.id == cursor }) else { throw URLError(.badURL) }
            end = index
        }
        let start = max(0, end - 20)
        return HMCommentPage(comments: Array(all[start..<end]), olderCursor: start > 0 ? all[start].id : nil,
                             totalCount: commentCount(for: item.id))
    }
    // PUT Fire membership: idempotent, never an increment.
    func setReaction(_ emoji: String, isReacted: Bool, for item: HMMediaItem) async throws -> HMItemReactionSummary {
        guard emoji == "🔥" else { throw HMInteractionError.unsupportedAction }
        try await Task.sleep(for: latency)
        let old = fire(for: item.id)
        let next = HMItemReactionSummary(count: old.count + (old.reactedByViewer == isReacted ? 0 : (isReacted ? 1 : -1)),
                                         reactedByViewer: isReacted)
        fires[item.id] = next
        return next
    }
    // POST a comment: the server assigns the ID, author and time.
    func sendChat(_ message: HMChatMessage, for item: HMMediaItem) async throws -> HMTimelineEvent? {
        try await Task.sleep(for: latency)
        commentCounts[item.id] = commentCount(for: item.id) + 1
        engagements[item.id]?.value?.updateCommentCount(commentCounts[item.id])
        return HMTimelineEvent(id: "br-own-\(UUID().uuidString.prefix(12))", offset: message.offset, kind: .chat,
                               author: "You", text: message.text, wallTime: Date())
    }

    // MARK: Synthetic crowd

    private func commentsFile(for itemID: String) -> BRDemoComments? {
        if let file = files[itemID] { return file }
        guard let clip = catalog.clip(forItemID: itemID),
              let file = try? BRDemoCatalog.load(BRDemoComments.self, resource: clip.comments) else { return nil }
        files[itemID] = file
        return file
    }
    private func fire(for itemID: String) -> HMItemReactionSummary {
        fires[itemID] ?? HMItemReactionSummary(count: catalog.clip(forItemID: itemID)?.counts.fire ?? 0, reactedByViewer: false)
    }
    private func commentCount(for itemID: String) -> Int {
        commentCounts[itemID] ?? catalog.clip(forItemID: itemID)?.counts.comments ?? 0
    }

    /// One task for the current item: the comment trickle (wall clock only) and the viewer walk,
    /// each on its own cadence from the clip's file.
    private func startTicker(for itemID: String) {
        ticker?.cancel(); ticker = nil
        tickingID = itemID
        guard let file = commentsFile(for: itemID) else { return }
        if audience[itemID] == nil { publishAudience(file.audience.start, for: itemID) }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.nextDelay(for: itemID, file: file) else { return }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.advance(itemID, by: delay, file: file)
            }
        }
    }
    private func nextDelay(for itemID: String, file: BRDemoComments) -> Double? {
        var state = progress[itemID] ?? Progress()
        if state.untilTick == nil, !file.audience.ticks.isEmpty {
            state.untilTick = file.audience.ticks[state.tick % file.audience.ticks.count].first ?? 5
        }
        if clock == .wall, state.untilComment == nil, !file.live.isEmpty {
            state.untilComment = liveRow(state.trickled, in: file).gap ?? 4
        }
        progress[itemID] = state
        return [state.untilTick, state.untilComment].compactMap { $0 }.min().map { max(0.05, $0) }
    }
    private func advance(_ itemID: String, by elapsed: Double, file: BRDemoComments) {
        guard var state = progress[itemID] else { return }
        if let remaining = state.untilTick.map({ $0 - elapsed }) {
            state.untilTick = remaining
            if remaining <= 0.01 {
                let tick = file.audience.ticks[state.tick % file.audience.ticks.count]
                publishAudience(Int(tick.last ?? Double(file.audience.start)), for: itemID)
                state.tick += 1; state.untilTick = nil
            }
        }
        if let remaining = state.untilComment.map({ $0 - elapsed }) {
            state.untilComment = remaining
            if remaining <= 0.01 {
                if trickle(state.trickled, for: itemID, file: file) { state.trickled += 1 }
                state.untilComment = nil
            }
        }
        progress[itemID] = state
    }
    /// Live rows repeat in order once used up, with a round suffix so each arrival is a new comment.
    private func liveRow(_ index: Int, in file: BRDemoComments) -> BRDemoComments.Row {
        file.live[file.live.startIndex + index % file.live.count]
    }
    private func trickle(_ index: Int, for itemID: String, file: BRDemoComments) -> Bool {
        guard let engagement = engagements[itemID]?.value else { return false }
        let row = liveRow(index, in: file), round = index / file.live.count
        engagement.upsertComment(row.event(id: round == 0 ? row.id : "\(row.id)~\(round)", wallTime: Date()))
        guard catalog.clip(forItemID: itemID)?.liveCounts == true else { return true }
        commentCounts[itemID] = commentCount(for: itemID) + 1
        engagement.updateCommentCount(commentCounts[itemID])
        if let bump = row.fireBump, bump > 0 {
            let old = fire(for: itemID)
            fires[itemID] = HMItemReactionSummary(count: old.count + bump, reactedByViewer: old.reactedByViewer)
            engagement.updateReactionSummary(fires[itemID]!, for: "🔥")
        }
        return true
    }
    // The badge reads the engagement; the source pushes the latest value and owns the cadence (1–10 s ticks).
    private func publishAudience(_ viewers: Int, for itemID: String) {
        audience[itemID] = viewers
        engagements[itemID]?.value?.updateAudienceCount(viewers)
        audienceChanged(itemID, viewers)
    }

    private final class WeakEngagement {
        weak var value: HMEngagement?
        init(_ value: HMEngagement) { self.value = value }
    }
}

/// Media-clock comments for one clip, sorted by offset.
@MainActor private final class BRDemoTimeline: HMStreamTimeline {
    let duration: TimeInterval
    private let sorted: [HMTimelineEvent]
    init(duration: TimeInterval, events: [HMTimelineEvent]) {
        self.duration = duration; self.sorted = events.sorted { $0.offset < $1.offset }
    }
    func events(in range: ClosedRange<TimeInterval>) -> [HMTimelineEvent] { sorted.filter { range.contains($0.offset) } }
    var density: [HMDensityBucket] { [] }
    var markers: [HMTimelineMarker] { [] }
}
