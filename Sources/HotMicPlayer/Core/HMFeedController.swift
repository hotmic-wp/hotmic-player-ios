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

    @ObservationIgnored private var proxy: HMCacheProxy?
    @ObservationIgnored private var requestTime: TimeInterval?
    @ObservationIgnored private var requestReason = "play"
    @ObservationIgnored private var hasStarted = false
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
            guard let self else { return }
            var metrics = event.metrics
            if event.kind == .viewStart || event.kind == .firstFrame {
                metrics["live_player_count"] = Double(self.pool.nodes.count)
                metrics["memory_bytes"] = HMMemorySample.footprint()
            }
            self.analytics.emit(HMPlaybackEvent(kind: event.kind, itemID: event.itemID, position: event.position, metrics: metrics, properties: event.properties), item: item)
        }
        pool.willRecycle = { [weak self] node, incoming in
            guard let self else { return }
            // Keep beacon SDKs (Mux) attached across a recycle rather than
            // tearing the monitored player down: a recycle is a videoChange.
            self.analytics.videoChange(playerKey: node.id, item: incoming)
        }
    }

    public convenience init(items: [HMMediaItem], configuration: HMPlayerConfiguration = .default, analytics: HMAnalyticsHub? = nil) {
        self.init(dataSource: HMStaticFeedDataSource(items: items, pageSize: max(1, items.count), loopsForever: false, simulatedLatency: .zero), configuration: configuration, analytics: analytics)
    }

    // MARK: - Content loading

    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        let began = ProcessInfo.processInfo.systemUptime
        await loadNextPage()
        if !items.isEmpty, isFeedVisible { await prepareTransport(); setActiveIndex(0, reason: .initial, requestedAt: began) }
    }

    private func prepareTransport() async {
        guard proxy == nil else { return }
        do {
            let created = try HMCacheProxy(configuration: configuration)
            try await created.start()
            created.onEvent = { [weak self] event, item in self?.analytics.emit(event, item: item) }
            proxy = created
        } catch { loadError = "Cache transport: \(error.localizedDescription)" }
    }

    /// Call at the user's tap, before presentation or asset work. Playlist
    /// browsing loads metadata only, so the first-video baseline stays cold.
    public func requestPlay(at index: Int) async {
        let began = ProcessInfo.processInfo.systemUptime
        await prepareTransport()
        setActiveIndex(index, reason: .programmatic, requestedAt: began)
        isFeedVisible = true
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
    public func setActiveIndex(_ index: Int, reason: ActivationReason = .swipe, requestedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard items.indices.contains(index) else { return }
        proxy?.cancelPrefetch()
        requestTime = requestedAt
        requestReason = reason == .swipe ? "swipe" : reason == .initial ? "initial" : "play"
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
        let node = pool.node(for: item, protecting: [item.id], playbackURL: proxy?.url(for: item))
        node.setMuted(isMuted)
        attachAnalytics(node: node, item: item)

        if isFeedVisible && !node.isActive {
            // The very first item of a session starts from the top; anything
            // the viewer has already watched resumes where they left it.
            let shouldRestore = configuration.restoresPlaybackPosition && reason != .initial
            proxy?.markPlayed(item)
            node.activate(startingAt: shouldRestore ? resumePositions[item.id] : nil, requestedAt: requestedAt, reason: requestReason, cachedBytes: proxy?.cachedByteCount(for: item) ?? 0)
        }

        for n in pool.nodes { n.onBufferChanged = { [weak self] in self?.updatePrefetch() } }
        pool.trim(keeping: windowItemIDs(around: index))
        if configuration.strategy == .S2 { prefetchWindow(around: index) }
        updatePrefetch()
        loadMoreIfNeeded(currentIndex: index)
    }

    // MARK: - Prefetch

    /// Item ids the pool must not evict: the active item plus its warm window.
    private func windowItemIDs(around index: Int) -> Set<String> {
        var ids: Set<String> = []
        if items.indices.contains(index) { ids.insert(items[index].id) }
        for offset in configuration.warmOffsets {
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
        for offset in configuration.warmOffsets {
            let neighbour = index + offset
            guard items.indices.contains(neighbour) else { continue }
            let item = items[neighbour]
            guard pool.existingNode(for: item) == nil else { continue }
            let node = pool.node(for: item, protecting: protectedIDs, playbackURL: proxy?.url(for: item))
            node.setMuted(isMuted)
        }
    }

    private func updatePrefetch() {
        guard isFeedVisible, let node = currentNode, node.isActive else { proxy?.cancelPrefetch(); return }
        let threshold = max(0, configuration.prefetch.startThreshold)
        let remaining = max(0, node.snapshot.duration - node.snapshot.currentTime)
        let fullyLoaded = node.snapshot.duration > 0 && node.snapshot.bufferedAhead >= remaining - 0.1
        let safe = node.snapshot.bufferedAhead >= threshold || fullyLoaded
        guard safe else {
            proxy?.cancelPrefetch()
            // Detaching warm items cancels their AVFoundation network work.
            // S2 intentionally preserves the original competing warm-pool path.
            if configuration.strategy == .S3, node.snapshot.timeToFirstFrame != nil {
                pool.trim(keeping: Set(currentItem.map { [$0.id] } ?? []))
            }
            return
        }
        prefetchWindow(around: activeIndex)
        let dataItems = configuration.prefetch.windowOffsets.compactMap { offset -> HMMediaItem? in
            let index = activeIndex + offset
            return items.indices.contains(index) ? items[index] : nil
        }
        proxy?.prefetch(dataItems, keeping: (currentItem.map { [$0] } ?? []) + dataItems)
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
        proxy?.cancelPrefetch()
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
        let node = pool.node(for: item, protecting: [item.id], playbackURL: proxy?.url(for: item))
        node.setMuted(isMuted)
        attachAnalytics(node: node, item: item)
        if node.isActive {
            node.play()
        } else {
            proxy?.markPlayed(item)
            node.activate(startingAt: configuration.restoresPlaybackPosition ? resumePositions[item.id] : nil,
                          requestedAt: requestTime ?? ProcessInfo.processInfo.systemUptime, reason: requestReason,
                          cachedBytes: proxy?.cachedByteCount(for: item) ?? 0)
        }
    }

    public func finishRun() async {
        pauseAll()
        for node in pool.nodes where node.isActive { node.deactivate(retainingPosition: true) }
        let waste = await proxy?.finish() ?? 0
        if let item = currentItem { analytics.emit(HMPlaybackEvent(kind: .runEnd, itemID: item.id, metrics: ["wasted_prefetch_bytes": Double(waste)]), item: item) }
    }

    public func teardown() {
        loadTask?.cancel()
        if let proxy { Task { _ = await proxy.finish() } }
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
        proxy?.configuration = configuration
        proxy?.cancelPrefetch()
        pool.trim(keeping: Set(currentItem.map { [$0.id] } ?? []))
        if let item = currentItem {
            let node = pool.node(for: item, protecting: [item.id], playbackURL: proxy?.url(for: item))
            if isFeedVisible, !node.isActive { node.activate() }
        }
        updatePrefetch()
    }
}
#endif
