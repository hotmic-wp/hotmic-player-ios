#if canImport(AVFoundation) && !os(macOS)
import AVFoundation
import Foundation
import Observation

/// The brain of a vertical feed.
///
/// Owns the item list, the active index, the recycled player pool, the prefetch
/// window and the analytics fan-out. Views observe it; they never drive playback
/// directly.
@MainActor
@Observable
public final class HMFeedController {

    // MARK: - Public state

    public private(set) var items: [HMMediaItem] = []
    public private(set) var activeIndex: Int = 0
    public private(set) var isLoadingPage = false
    public private(set) var hasMoreContent = true
    public private(set) var loadError: String?

    /// Global mute. Vertical feeds are almost always sound-on, but demos aren't.
    public var isMuted: Bool {
        didSet { for node in pool.nodes { node.setMuted(isMuted) } }
    }

    public var configuration: HMPlayerConfiguration {
        didSet { applyConfiguration() }
    }

    /// Set false when the feed scrolls out of view or the app backgrounds.
    public var isFeedVisible = true {
        didSet { isFeedVisible ? resumeActive() : pauseAll() }
    }

    @ObservationIgnored public let pool: HMPlayerPool
    @ObservationIgnored public let analytics: HMAnalyticsHub

    // MARK: - Private

    @ObservationIgnored private let dataSource: HMFeedDataSource
    @ObservationIgnored private var nextCursor: String?
    @ObservationIgnored private var timelines: [String: HMStreamTimeline] = [:]
    @ObservationIgnored private var resumePositions: [String: TimeInterval] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Builds the engagement timeline for an item. Mocked by default.
    @ObservationIgnored public var timelineProvider: (HMMediaItem) -> HMStreamTimeline

    public init(
        dataSource: HMFeedDataSource,
        configuration: HMPlayerConfiguration = .default,
        analytics: HMAnalyticsHub? = nil,
        timelineProvider: ((HMMediaItem) -> HMStreamTimeline)? = nil
    ) {
        self.dataSource = dataSource
        self.configuration = configuration
        self.analytics = analytics ?? HMAnalyticsHub()
        self.isMuted = configuration.startsMuted
        self.pool = HMPlayerPool(configuration: configuration)
        self.timelineProvider = timelineProvider ?? { item in
            HMMockTimeline(itemID: item.id, duration: item.durationHint ?? 20)
        }

        pool.onEvent = { [weak self] event, item in
            self?.analytics.emit(event, item: item)
        }
        pool.willRecycle = { [weak self] node, incoming in
            guard let self else { return }
            // Keep beacon SDKs (Mux) attached across a recycle rather than
            // tearing the monitored player down: a recycle is a videoChange.
            self.analytics.videoChange(playerKey: node.id, item: incoming)
        }
    }

    // MARK: - Content loading

    public func start() async {
        guard items.isEmpty else { return }
        if configuration.managesAudioSession { HMAudioSession.activatePlayback() }
        await loadNextPage()
        if !items.isEmpty { setActiveIndex(0, reason: .initial) }
    }

    public func loadNextPage() async {
        guard !isLoadingPage, hasMoreContent else { return }
        isLoadingPage = true
        loadError = nil
        defer { isLoadingPage = false }
        do {
            let page = try await dataSource.loadPage(cursor: nextCursor)
            items.append(contentsOf: page.items)
            nextCursor = page.nextCursor
            hasMoreContent = page.nextCursor != nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Called by the feed view as the viewer nears the end of loaded content.
    public func loadMoreIfNeeded(currentIndex: Int) {
        guard hasMoreContent, !isLoadingPage else { return }
        guard currentIndex >= items.count - 3 else { return }
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.loadNextPage() }
    }

    // MARK: - Paging

    /// Why the active index changed. Affects position restore, and is worth
    /// keeping distinct for analytics later.
    public enum ActivationReason { case initial, swipe, programmatic }

    /// The single entry point for "the viewer is now looking at index N".
    public func setActiveIndex(_ index: Int, reason: ActivationReason = .swipe) {
        guard items.indices.contains(index) else { return }
        let previousIndex = activeIndex
        let isSameItem = previousIndex == index && currentNode?.isActive == true
        activeIndex = index

        if !isSameItem, items.indices.contains(previousIndex), previousIndex != index {
            if let previous = pool.existingNode(for: items[previousIndex]), previous.isActive {
                resumePositions[items[previousIndex].id] = previous.snapshot.currentTime
                previous.deactivate(retainingPosition: configuration.restoresPlaybackPosition)
            }
        }

        let item = items[index]
        let node = pool.node(for: item, protecting: windowItemIDs(around: index))
        node.setMuted(isMuted)
        attachAnalytics(node: node, item: item)

        if isFeedVisible && !node.isActive {
            // The very first item of a session starts from the top; anything
            // the viewer has already watched resumes where they left it.
            let shouldRestore = configuration.restoresPlaybackPosition && reason != .initial
            node.activate(startingAt: shouldRestore ? resumePositions[item.id] : nil)
        }

        prefetchWindow(around: index)
        pool.trim(keeping: windowItemIDs(around: index))
        loadMoreIfNeeded(currentIndex: index)
    }

    // MARK: - Prefetch

    /// Item ids the pool must not evict: the active item plus its warm window.
    private func windowItemIDs(around index: Int) -> Set<String> {
        var ids: Set<String> = []
        if items.indices.contains(index) { ids.insert(items[index].id) }
        for offset in configuration.prefetch.windowOffsets {
            let neighbour = index + offset
            if items.indices.contains(neighbour) { ids.insert(items[neighbour].id) }
        }
        return ids
    }

    /// Warm the neighbours of `index`, nearest first.
    ///
    /// This is the whole trick behind an instant-feeling feed: by the time the
    /// viewer's thumb lifts, the next item already has its first segments.
    private func prefetchWindow(around index: Int) {
        let protectedIDs = windowItemIDs(around: index)
        for offset in configuration.prefetch.windowOffsets {
            let neighbour = index + offset
            guard items.indices.contains(neighbour) else { continue }
            let item = items[neighbour]
            guard pool.existingNode(for: item) == nil else { continue }
            let node = pool.node(for: item, protecting: protectedIDs)
            node.setMuted(isMuted)
        }
    }

    // MARK: - Access for views

    public var currentItem: HMMediaItem? {
        items.indices.contains(activeIndex) ? items[activeIndex] : nil
    }

    public var currentNode: HMPlayerNode? {
        currentItem.flatMap { pool.existingNode(for: $0) }
    }

    /// The node rendering `item`, if one is assigned. Nil means "not warmed yet"
    /// and the cell should show its poster.
    public func node(for item: HMMediaItem) -> HMPlayerNode? {
        pool.existingNode(for: item)
    }

    public func snapshot(for item: HMMediaItem) -> HMPlaybackSnapshot {
        pool.existingNode(for: item)?.snapshot ?? HMPlaybackSnapshot()
    }

    public func timeline(for item: HMMediaItem) -> HMStreamTimeline {
        if let existing = timelines[item.id] { return existing }
        let created = timelineProvider(item)
        timelines[item.id] = created
        return created
    }

    // MARK: - Transport passthrough

    public func togglePlayPause() { currentNode?.togglePlayPause() }
    public func toggleMute() { isMuted.toggle() }
    public func seek(toProgress progress: Double) { currentNode?.seek(toProgress: progress) }

    public func pauseAll() {
        for node in pool.nodes where node.isActive {
            if let item = node.item { resumePositions[item.id] = node.snapshot.currentTime }
            node.pause()
        }
    }

    /// Resume the active item, promoting it if it was only ever warmed.
    ///
    /// Entering the feed from another screen lands here: the item may already
    /// be buffered but never activated, in which case it needs a real
    /// activation so the view is counted and time-to-first-frame is measured.
    public func resumeActive() {
        guard isFeedVisible, let item = currentItem else { return }
        let node = pool.node(for: item, protecting: windowItemIDs(around: activeIndex))
        node.setMuted(isMuted)
        attachAnalytics(node: node, item: item)
        if node.isActive {
            node.play()
        } else {
            node.activate(startingAt: configuration.restoresPlaybackPosition ? resumePositions[item.id] : nil)
        }
    }

    public func teardown() {
        loadTask?.cancel()
        for node in pool.nodes { analytics.detach(playerKey: node.id) }
        pool.releaseAll()
        if configuration.managesAudioSession { HMAudioSession.deactivate() }
    }

    // MARK: - Internals

    private func attachAnalytics(node: HMPlayerNode, item: HMMediaItem) {
        analytics.attach(playerLayer: node.playerLayer, playerKey: node.id, item: item)
    }

    private func applyConfiguration() {
        pool.configuration = configuration
        pool.resize(to: configuration.poolSize)
        pool.applyConfiguration()
        prefetchWindow(around: activeIndex)
        pool.trim(keeping: windowItemIDs(around: activeIndex))
    }
}
#endif
