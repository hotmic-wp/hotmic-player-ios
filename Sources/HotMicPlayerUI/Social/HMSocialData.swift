#if os(iOS)
import SwiftUI
import Observation
import HotMicPlayer

/// Backend-independent comment. IDs must be stable across page loads.
public struct HMSocialComment: Identifiable, Equatable, Sendable {
    /// Stable identity used to reconcile this row across updates.
    public var id: String
    /// Display name supplied by the host.
    public var author: String
    /// Comment text supplied by the host.
    public var text: String
    /// Creates this component with host-supplied data and actions.
    public init(id: String, author: String, text: String) {
        self.id = id; self.author = author; self.text = text
    }
}

/// Data in: nil counts stay hidden. Supply preview candidates in the host's preferred order.
public struct HMSocialContent: Equatable, Sendable {
    /// Primary media title.
    public var title: String
    /// Body text, truncated until expanded by the viewer.
    public var description: String
    /// Host-routed tag strings; the display adds a leading hash when absent.
    public var hashtags: [String]
    /// Optional community label above the title.
    public var community: String?
    /// Authoritative Fire count; nil hides the count.
    public var fireCount: Int?
    /// Authoritative comment count; nil hides the count.
    public var commentCount: Int?
    /// Authoritative share count; nil hides the count.
    public var shareCount: Int?
    /// Whether the viewer currently belongs to the Fire reaction.
    public var isReacted: Bool
    /// Host-selected preview candidates in preferred rotation order.
    public var previewComments: [HMSocialComment]
    /// Loaded comment rows, in display order.
    public var comments: [HMSocialComment]
    /// Creates this component with host-supplied data and actions.
    public init(title: String, description: String = "", hashtags: [String] = [], community: String? = nil,
                fireCount: Int? = nil, commentCount: Int? = nil, shareCount: Int? = nil, isReacted: Bool = false,
                previewComments: [HMSocialComment] = [], comments: [HMSocialComment] = []) {
        self.title = title; self.description = description; self.hashtags = hashtags; self.community = community
        self.fireCount = fireCount; self.commentCount = commentCount; self.shareCount = shareCount
        self.isReacted = isReacted; self.previewComments = previewComments; self.comments = comments
    }
}

/// Supply an observable implementation backed directly by your service, or use HMEngagementSocialAdapter.
/// Changes read by the views participate in SwiftUI Observation. Methods run on the main actor;
/// implementations own optimistic state, ordering and rollback. Throw to retain the draft and display an error.
@MainActor public protocol HMSocialDataSource: AnyObject {
    /// Current observable item metadata, counts and comment rows.
    var content: HMSocialContent { get }
    /// Whether membership actions are supported for the current item.
    var canFire: Bool { get }
    /// Whether comment submission is supported for the viewer.
    var canPost: Bool { get }
    /// Whether an initial or older comment page remains available.
    var canLoadMore: Bool { get }
    /// Sets intended membership; the implementation owns serialization and rollback.
    func setReacted(_ reacted: Bool) async throws
    /// Loads the next page while preserving stable row identities.
    func loadMoreComments() async throws
    /// Submits the draft; throw on failure so the composer retains it.
    func postComment(_ text: String) async throws
}

/// A small observable model for hosts that already maintain authoritative state elsewhere.
/// Action closures should publish resulting state back to `content`; no backend is required by the kit.
@MainActor @Observable public final class HMSocialModel: HMSocialDataSource {
    /// Current host-supplied social data, observed by the UI.
    public var content: HMSocialContent
    /// Whether item reaction membership can be changed.
    public var canFire: Bool
    /// Whether the viewer can submit a comment.
    public var canPost: Bool
    /// Whether another comment page can be requested.
    public var canLoadMore: Bool
    /// Host action; publish the authoritative or optimistic membership back to content.
    @ObservationIgnored public var onSetReacted: (Bool) async throws -> Void
    /// Host paging action; publish rows and whether more pages remain.
    @ObservationIgnored public var onLoadMore: () async throws -> Void
    /// Host submission action; publish the resulting rows and counts.
    @ObservationIgnored public var onPost: (String) async throws -> Void
    /// Creates this component with host-supplied data and actions.
    public init(content: HMSocialContent, canFire: Bool = true, canPost: Bool = true, canLoadMore: Bool = false,
                onSetReacted: @escaping (Bool) async throws -> Void = { _ in },
                onLoadMore: @escaping () async throws -> Void = {}, onPost: @escaping (String) async throws -> Void = { _ in }) {
        self.content = content; self.canFire = canFire; self.canPost = canPost; self.canLoadMore = canLoadMore
        self.onSetReacted = onSetReacted; self.onLoadMore = onLoadMore; self.onPost = onPost
    }
    /// Sets intended Fire membership through the backend; implementations own ordering and rollback.
    public func setReacted(_ reacted: Bool) async throws { try await onSetReacted(reacted) }
    /// Requests the next page; implementations preserve stable IDs and their paging cursor.
    public func loadMoreComments() async throws { try await onLoadMore() }
    /// Submits text; throw on failure so the composer can preserve its draft.
    public func postComment(_ text: String) async throws { try await onPost(text) }
}

/// Adapts item counts, membership, paged comments and posting from HMEngagement (including Connect sources).
/// Timed replay totals are deliberately never substituted for authoritative item counts.
@MainActor @Observable public final class HMEngagementSocialAdapter: HMSocialDataSource {
    /// Public engagement object providing item state and backend actions.
    public let engagement: HMEngagement
    /// Host text, tags and community; item engagement fills counts and comments.
    public var metadata: HMSocialContent
    /// Host controls which candidates appear; selection is independent of the sheet's loaded pages.
    public var previewSelection: ([HMSocialComment]) -> [HMSocialComment] { didSet { selectionRevision += 1 } }
    /// Match the overlay theme; its primary reaction selects the backend membership and count.
    public var theme: HMTheme
    private var selectionRevision = 0
    @ObservationIgnored private var mappedContent: HMSocialContent?
    private var replayRevision = 0
    @ObservationIgnored private var replayTime: TimeInterval = 0
    @ObservationIgnored private var replayRows: [HMSocialComment] = []
    @ObservationIgnored private var replayTask: Task<Void, Never>?
    @ObservationIgnored private var replayOwners: Set<UUID> = []
    @ObservationIgnored private var replaySourceRevision: Int?
    @ObservationIgnored private var replayIsTimed = false
    @ObservationIgnored private var replayOffsets: [TimeInterval] = []
    @ObservationIgnored private var replayCursor = 0
    @ObservationIgnored private var lastReplayOffset: TimeInterval?
    @ObservationIgnored private var mappedKey: MappingKey?
    private struct MappingKey: Equatable {
        var revision: Int
        var replay: Int
        var metadata: HMSocialContent
        var reaction: String
        var selection: Int
    }
    /// Creates this component with host-supplied data and actions.
    public init(engagement: HMEngagement, metadata: HMSocialContent, theme: HMTheme = .default,
                previewSelection: @escaping ([HMSocialComment]) -> [HMSocialComment] = { Array($0.suffix(3)) }) {
        self.engagement = engagement; self.metadata = metadata; self.theme = theme; self.previewSelection = previewSelection
    }
    /// Lazily maps observable backend state. Playback snapshots are never dependencies of this getter.
    public var content: HMSocialContent {
        let key = MappingKey(revision: engagement.revision, replay: replayRevision,
            metadata: metadata, reaction: theme.primaryReaction, selection: selectionRevision)
        if mappedKey == key, let mappedContent { return mappedContent }
        var value = metadata
        let summary = engagement.reactionSummary(for: theme.primaryReaction)
        value.fireCount = summary?.count; value.isReacted = summary?.reactedByViewer ?? false
        value.commentCount = engagement.commentCount
        value.comments = engagement.comments(near: replayTime).map { HMSocialComment(id: $0.rowID, author: $0.author, text: $0.text) }
        value.previewComments = previewSelection(value.comments)
        mappedKey = key; mappedContent = value
        return value
    }
    /// Enables timed replay for one view instance while current and visible. The kit wires this automatically.
    /// Keep a stable UUID per view and deactivate that same token when hidden. Other visible owners stay active.
    public func setReplayActive(_ active: Bool, for owner: UUID) {
        if active {
            replayOwners.insert(owner)
        } else {
            replayOwners.remove(owner)
        }
        guard !replayOwners.isEmpty else {
            replayTask?.cancel(); replayTask = nil
            return
        }
        guard replayTask == nil, refreshReplay() else { return }
        replayTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard self?.refreshReplay() == true else { return }
            }
        }
    }
    // Internal synchronous sampling also lets tests drive exact clock boundaries without wall-clock sleeps.
    @discardableResult func refreshReplay() -> Bool {
        guard !replayOwners.isEmpty else { return false }
        let revision = engagement.revision
        if replaySourceRevision != revision {
            replaySourceRevision = revision
            lastReplayOffset = nil
            replayIsTimed = false
            guard let offsets = engagement.commentReplayOffsets else {
                replayTask?.cancel(); replayTask = nil
                return false
            }
            replayIsTimed = true
            replayOffsets = offsets
        }
        // A stopped item-comment source remains stopped even if another view activates it.
        guard replayIsTimed else { return false }
        replayTime = engagement.currentMediaTime
        let offset = engagement.timelineOffset(forMediaTime: replayTime)
        let previousCursor = replayCursor
        let reset = lastReplayOffset == nil || offset < lastReplayOffset!
        if reset {
            var low = 0, high = replayOffsets.count
            while low < high {
                let middle = (low + high) / 2
                if replayOffsets[middle] <= offset { low = middle + 1 } else { high = middle }
            }
            replayCursor = low
        } else {
            while replayCursor < replayOffsets.count, replayOffsets[replayCursor] <= offset { replayCursor += 1 }
        }
        lastReplayOffset = offset
        guard reset || replayCursor != previousCursor else { return true }
        let rows = engagement.comments(near: replayTime).map { HMSocialComment(id: $0.rowID, author: $0.author, text: $0.text) }
        if rows != replayRows { replayRows = rows; replayRevision += 1 }
        return true
    }
    deinit { replayTask?.cancel() }
    /// Whether item reaction membership can be changed.
    public var canFire: Bool { engagement.supports(.toggleReaction) && engagement.reactionSummary(for: theme.primaryReaction) != nil }
    /// Whether the viewer can submit a comment.
    public var canPost: Bool { engagement.supports(.sendChat) }
    /// Whether another comment page can be requested.
    public var canLoadMore: Bool {
        engagement.supports(.loadComments) && (!engagement.hasLoadedComments || engagement.olderCommentsCursor != nil)
    }
    /// Sets intended Fire membership through the backend; implementations own ordering and rollback.
    public func setReacted(_ reacted: Bool) async throws { try await engagement.setReaction(theme.primaryReaction, reacted: reacted) }
    /// Requests the next page; implementations preserve stable IDs and their paging cursor.
    public func loadMoreComments() async throws { try await engagement.loadComments() }
    /// Submits text; throw on failure so the composer can preserve its draft.
    public func postComment(_ text: String) async throws { try await engagement.sendChat(text) }
}

/// Replacement rail inputs. Use these actions to retain the kit's Fire and sheet behavior.
public struct HMSocialRailContext {
    /// Current item metadata, optional counts and viewer membership.
    public let content: HMSocialContent
    /// Positive Fire event shared by the custom rail and surface burst.
    public let fireEvent: Int
    /// Whether the source can change reaction membership.
    public let canFire: Bool
    /// Activates the same Fire event as a surface double tap.
    public let fire: () -> Void
    /// Opens the interactive comment sheet.
    public let openComments: () -> Void
    /// Invokes the host share callback.
    public let share: () -> Void
    /// Report the custom Fire glyph's frame in the named hm-social-overlay coordinate space.
    public let fireFrameChanged: (CGRect) -> Void
}

/// Replacement metadata inputs, with the kit's host navigation callbacks.
public struct HMSocialMetadataContext {
    /// Current title, description, community and hashtags.
    public let content: HMSocialContent
    /// Routes an activated hashtag to the host.
    public let hashtagTapped: (String) -> Void
    /// Opens the kit's expanded metadata sheet without competing with feed paging.
    public let expand: () -> Void
}

/// Events out. Share should present native host UI; HMShareSheet is the default helper.
public struct HMSocialCallbacks {
    /// Called when a viewer activates a hashtag.
    public var hashtagTapped: (String) -> Void = { _ in }
    /// Called to present the host native share UI for an item.
    public var share: (HMMediaItem) -> Void = { _ in }
    /// Called after a successful membership action with its requested state.
    public var fireToggled: (HMMediaItem, Bool) -> Void = { _, _ in }
    /// Called after a successful submission with the submitted text.
    public var commentPosted: (HMMediaItem, String) -> Void = { _, _ in }
    /// Called once for each sheet opening or closing, with the originating item.
    public var sheetChanged: (HMMediaItem, Bool) -> Void = { _, _ in }
    /// Creates this component with host-supplied data and actions.
    public init() {}
}

/// Configuration is independent of backend and theme. Heights are points, excluding the system safe area.
public struct HMSocialOptions: Equatable {
    /// How the comment sheet rests after a drag.
    public enum SheetMode: Equatable, Sendable {
        /// Any dragged height is kept; dragging below the close threshold dismisses the sheet.
        case continuous
        /// A release snaps to squeezed, expanded or closed. The squeezed video keeps this fraction of the viewport height.
        case snapped(squeezeFraction: Double)
    }
    /// Height of persistent host navigation, excluding the system bottom safe area.
    public var hostNavigationHeight: CGFloat = 0
    /// Shows a mute button when true; defaults to false.
    public var showsMute = false
    /// Enables dragging the progress bar to seek; defaults to false.
    public var allowsScrubbing = false
    /// Hides metadata and progress during ads when the host explicitly opts out; defaults to false.
    public var hidesMetadataDuringAds = false
    /// Preferred sheet height in points, clamped to the available viewport.
    public var sheetHeight: CGFloat = 380
    /// Visible duration, followed by a hidden gap. No preview persists indefinitely.
    public var previewDuration: TimeInterval = 4
    /// Nil shows only the host-selected first candidate once per item. Otherwise rotates after this interval.
    public var previewRotationInterval: TimeInterval? = 7
    /// Rest behavior of the comment sheet; defaults to continuous dragging.
    public var sheetMode: SheetMode = .continuous
    /// Keeps feed paging available while the sheet is open; false blocks swipes until it closes. Defaults to true.
    public var allowsPagingWhileSheetOpen = true
    /// Closes an open sheet when the visible video is tapped, instead of ignoring the tap; defaults to false.
    public var closesSheetOnVideoTap = false
    /// Shows buffering and failure status with tap-to-retry inside the visible video frame; defaults to false.
    public var showsPlaybackStatus = false
    /// Creates this component with host-supplied data and actions.
    public init() {}
}
#endif
