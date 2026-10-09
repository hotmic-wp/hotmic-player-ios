#if canImport(AVFoundation) && !os(macOS)
import AVFoundation
import Foundation
import Observation

/// The partner SDK entry point. Owns a VOD playlist, playback, prefetch and events.
/// All mutations are synchronous and atomic on the main actor. During a swipe,
/// edits preserve a swipe unless the current or destination ID changes position.
@MainActor @Observable public final class HMPlayer {
    private var playlist = HMPlaylistState()
    /// Loaded playlist entries, in display order.
    public var items: [HMMediaItem] { playlist.items }
    /// Index of the last committed current item; zero while idle.
    public var activeIndex: Int { failureIdle ? 0 : playlist.index }
    /// Index of the current entry, or nil when empty or idle after failures.
    public var currentIndex: Int? { currentItem == nil ? nil : playlist.index }
    /// Last committed current entry, or nil while idle.
    public var currentItem: HMMediaItem? { failureIdle ? nil : playlist.current }
    /// Current playback state, observed by SwiftUI through the underlying snapshot.
    public var snapshot: HMPlaybackSnapshot { currentNode?.snapshot ?? pendingSnapshot }
    /// True while requesting a page from the optional playlist source.
    public private(set) var isLoadingPage = false
    /// Whether the source has another page. False without a source.
    public private(set) var hasMoreContent = false
    /// Latest recoverable error description; a successful operation clears it.
    public private(set) var loadError: String?
    /// Most recent event, also available to Observation clients.
    public private(set) var lastEvent: HMPlayerEvent?
    /// Increments after each effective playlist edit. Appends preserve in-flight swipes.
    public private(set) var playlistRevision = 0
    /// Optional paging adapter. Assigning a different source resets its cursor and invalidates its pending page.
    public var playlistSource: HMPlaylistSource? {
        didSet { pageGeneration += 1; loadTask?.cancel(); loadTask = nil; pageTaskID = UUID(); isLoadingPage = false; resetPagingCursor(); scheduleFailedItemAdvance() }
    }
    /// Playback and prefetch settings. Updating these may resize the engine pool.
    public var configuration: HMPlayerConfiguration { didSet { applyConfiguration() } }
    /// Replaceable measured-performance policy. Fixed mode bypasses custom providers.
    @ObservationIgnored public var prefetchPolicy: any HMPrefetchPolicyProviding = HMAdaptivePrefetchPolicy() {
        didSet { prefetchIdentity = ""; updatePrefetch(force: true) }
    }
    /// Last applied, app-clamped decision, including its reason.
    public private(set) var prefetchPlan: HMPrefetchPlan?
    /// Mutes every current and prepared player synchronously.
    public var isMuted: Bool { didSet { for node in pool.nodes { node.setMuted(isMuted) } } }
    /// Pause when hidden or backgrounded. Resume is synchronous for a resolved, prepared current item.
    public var isFeedVisible = true {
        didSet {
            guard isFeedVisible != oldValue else { return }
            if isFeedVisible { Task { [weak self] in await self?.prepareTransport() }; if configuration.managesAudioSession { HMAudioSession.activatePlayback() }; refreshWindow() }
            else { pauseAll() }
        }
    }
    /// Analytics fan-out, independent of the player event stream.
    @ObservationIgnored public let analytics: HMAnalyticsHub
    /// Independent ordered subscription, buffered up to 256 events. Cancel the consuming task when finished.
    public var events: AsyncStream<HMPlayerEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.subscribers[id] = nil } }
        }
    }
    /// Number of engine slots holding media; intended for diagnostics, without exposing native players.
    @_spi(Benchmark) public var preparedItemCount: Int { pool.busyCount }

    /// Read-only interaction state: feed touches/page motion or a bounded partner interaction.
    public var isInteracting: Bool { pageIsMoving || feedIsTouching || partnerIsInteracting }
    private var feedIsTouching = false
    private var partnerIsInteracting = false
    private var pageIsMoving = false
    @ObservationIgnored private var interactionTimeoutTask: Task<Void, Never>?
    /// Defers automatic failure skips for a custom control. Repeated calls renew the 30-second timeout.
    public func beginInteraction() { beginInteraction(timeout: .seconds(30)) }
    func beginInteraction(timeout: Duration) {
        guard !ended else { return }
        partnerIsInteracting = true
        interactionTimeoutTask?.cancel()
        interactionTimeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.endInteraction()
        }
    }
    /// Ends a custom control interaction early; otherwise it expires automatically after 30 seconds.
    public func endInteraction() {
        partnerIsInteracting = false
        interactionTimeoutTask?.cancel(); interactionTimeoutTask = nil
        scheduleFailedItemAdvance()
    }
    func setFeedTouching(_ touching: Bool) {
        feedIsTouching = touching
        if !touching { scheduleFailedItemAdvance() }
    }
    private var failureIdle = false
    @ObservationIgnored private var terminalFailures: Set<HMMediaItem> = []
    @ObservationIgnored private var failureAdvanceTask: Task<Void, Never>?
    @ObservationIgnored private var feedSurfaces = 0
    @ObservationIgnored private var failurePageID: String?
    @ObservationIgnored private var deferredFailureCommit: (id: String, time: TimeInterval)?
    @ObservationIgnored private var networkFailures: [HMMediaItem: HMNetworkRetry] = [:]
    @ObservationIgnored private var networkRetryTask: Task<Void, Never>?
    @ObservationIgnored private var connectivityMonitor: HMConnectivityMonitor?
    @ObservationIgnored private var lastPathSatisfied: Bool?

    var requestedPageID: String?
    var requestedPageIndex: Int? {
        if failurePageID == requestedPageID, feedIsTouching || partnerIsInteracting { return nil }
        return requestedPageID.flatMap { id in items.firstIndex { $0.id == id } }
    }
    var pageRequestID = UUID()
    @ObservationIgnored let pool: HMPlayerPool
    @ObservationIgnored private let resolver: HMItemResolver?
    @ObservationIgnored private let interactions: HMInteractionSource
    @ObservationIgnored private let resolutions = HMResolutionStore()
    @ObservationIgnored private var resolutionTasks: [HMMediaItem: Task<Void, Never>] = [:]
    @ObservationIgnored private var resolutionFailures: [HMMediaItem: HMResolutionRetry] = [:]
    @ObservationIgnored private var resolutionRetryTask: Task<Void, Never>?
    @ObservationIgnored private var interactionCurrent: HMMediaItem?
    @ObservationIgnored private var interactionNext: HMMediaItem?
    @ObservationIgnored private var timelines: [HMMediaItem: HMStreamTimeline] = [:]
    @ObservationIgnored private var engagements: [HMMediaItem: HMEngagement] = [:]
    @ObservationIgnored private var subscribers: [UUID: AsyncStream<HMPlayerEvent>.Continuation] = [:]
    @ObservationIgnored private var proxy: HMCacheProxy?
    @ObservationIgnored private var transportTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var pageGeneration = 0
    @ObservationIgnored private var cursorGeneration = 0
    @ObservationIgnored private var pagingRetry = HMPagingRetry()
    @ObservationIgnored private var pagingRetryTask: Task<Void, Never>?
    @ObservationIgnored private var pageTaskID = UUID()
    @ObservationIgnored private var prefetchIdentity = ""
    @ObservationIgnored private var measurements = HMPrefetchMeasurements()
    @ObservationIgnored private var activatedAt: TimeInterval?
    @ObservationIgnored private var arrivalDwell: TimeInterval?
    @ObservationIgnored private var lastDecisionAt = -Double.infinity
    @ObservationIgnored private var nextCursor: String?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var ended = false
    @ObservationIgnored private var wantsPlayback = true
    @ObservationIgnored private var prefetchSafe = false
    @ObservationIgnored private var requestTime = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored private var requestReason = "initial"
    @ObservationIgnored private var resumePositions: [String: TimeInterval] = [:]
    @ObservationIgnored private var nearingEndKey = ""
    private var pendingSnapshot = HMPlaybackSnapshot()

    /// Creates an empty player. Supply only the adapters your app needs; no Core dependency is required.
    public init(configuration: HMPlayerConfiguration = .default, resolver: HMItemResolver? = nil,
                interactions: HMInteractionSource? = nil, analytics: HMAnalyticsHub? = nil) {
        self.configuration = configuration; self.resolver = resolver
        // Without a source, demo engagement is display-only: no action controls a viewer could mistake for real.
        self.interactions = interactions ?? HMMockInteractionSource(capabilities: .readOnly)
        self.analytics = analytics ?? HMAnalyticsHub(); isMuted = configuration.startsMuted
        pool = HMPlayerPool(configuration: configuration)
        pool.onEvent = { [weak self] event, item in self?.handle(event, item: item) }
        pool.willRecycle = { [weak self] node, item in self?.analytics.videoChange(playerKey: node.id, item: item) }
        for node in pool.nodes { node.onBufferChanged = { [weak self] in self?.updatePrefetch() } }
        connectivityMonitor = HMConnectivityMonitor { [weak self] satisfied in
            Task { @MainActor [weak self] in self?.connectivityChanged(satisfied: satisfied) }
        }
    }

    /// Switches to `items[startAt]` and resets the source cursor to nil, including its retry budget.
    /// A pending page finishes but is ignored. Empty with startAt zero becomes idle; invalid edits return false and emit an error.
    @discardableResult public func replaceAll(_ items: [HMMediaItem], startAt: Int = 0) -> Bool {
        mutate(replacingCurrent: true) { try $0.replaceAll(items, startAt: startAt) }
    }
    /// Replaces every entry after current, preserving the current player's clock, buffer and layer.
    @discardableResult public func replaceUpcoming(_ items: [HMMediaItem]) -> Bool { mutate { try $0.replaceUpcoming(items) } }
    /// Inserts entries immediately after current; on an empty list creates the playlist.
    @discardableResult public func insertNext(_ items: [HMMediaItem]) -> Bool { mutate { try $0.insertNext(items) } }
    /// Adds entries at the end without interrupting current playback.
    @discardableResult public func append(_ items: [HMMediaItem]) -> Bool { appendItems(items, fromSource: false) }
    private func appendItems(_ items: [HMMediaItem], fromSource: Bool) -> Bool { mutate { try $0.append(items) } }
    /// Removes IDs. Removing current selects the next survivor, then previous; removing all becomes idle.
    @discardableResult public func remove(ids: Set<String>) -> Bool { mutate { $0.remove(ids: ids) } }

    private func mutate(replacingCurrent: Bool = false, _ edit: (inout HMPlaylistState) throws -> Void) -> Bool {
        guard !ended else { return false }
        var result = playlist
        do { try edit(&result) } catch { report(error as? HMPlayerError ?? .playlistSource(error.localizedDescription)); return false }
        guard replacingCurrent || result != playlist else { return true }
        let old = currentItem
        let oldWindow = windowItems
        let preservesMove = HMPagePosition.survives(old: items.map(\.id), new: result.items.map(\.id),
            current: old?.id, destination: requestedPageID)
        let changesCurrent = replacingCurrent || old != result.current
        if changesCurrent { saveAndDeactivate() }
        // A playlist edit invalidates the automatic-failure request's provenance.
        if failurePageID != nil { requestedPageID = nil; pageRequestID = UUID() }
        failurePageID = nil; deferredFailureCommit = nil
        playlist = result
        networkFailures = networkFailures.filter { items.contains($0.key) }
        terminalFailures.formIntersection(Set(items))
        if replacingCurrent { terminalFailures.removeAll(); networkFailures.removeAll(); failureIdle = false }
        else if changesCurrent { failureIdle = false }
        loadError = nil; playlistRevision += 1
        if !preservesMove { requestedPageID = nil; pageRequestID = UUID() }
        // Edits do not supersede a source request: its page is merged against the
        // latest playlist on arrival. replaceAll resets the cursor and ignores an old
        // response without cancelling its fetch. Source assignment or teardown cancels it.
        if replacingCurrent { resetPagingCursor(); resumePositions.removeAll(); pool.releaseAll() }
        if oldWindow != windowItems { proxy?.cancelPrefetch(); prefetchSafe = false; prefetchIdentity = "" }
        if changesCurrent {
            if let currentItem { resolutionFailures[currentItem] = nil }
            requestTime = ProcessInfo.processInfo.systemUptime; requestReason = "play"
            pendingSnapshot = HMPlaybackSnapshot(); pendingSnapshot.state = currentItem == nil ? .idle : .loading
            emit(.currentItemChanged(currentItem))
        }
        emit(.playlistChanged(items))
        refreshWindow(); checkEnd(); scheduleFailedItemAdvance()
        return true
    }

    /// Begins playback, or resumes the current item without resetting its position.
    public func play() { wantsPlayback = true; resumeActive(); refreshWindow() }
    /// Pauses playback without changing the playlist or current position.
    public func pause() { wantsPlayback = false; currentNode?.pause() }
    /// Seeks to a VOD time in seconds, clamped to the known duration.
    public func seek(to seconds: TimeInterval) {
        guard seconds.isFinite, seconds >= 0 else { report(.invalidSeek, item: currentItem); return }
        currentNode?.seek(to: seconds)
    }
    /// Moves to the next entry, if any.
    public func next() { navigate(to: activeIndex + 1) }
    /// Moves to the previous entry, if any.
    public func previous() { navigate(to: activeIndex - 1) }
    /// Moves to a playlist ID. An unknown ID emits an invalid-index error.
    public func jump(toID id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { report(.invalidIndex(-1)); return }
        navigate(to: index)
    }
    private func navigate(to index: Int, reason: String = "play", requestedAt: TimeInterval = ProcessInfo.processInfo.systemUptime, retryFailed: Bool = true) {
        guard items.indices.contains(index), !ended else { return }
        let changesCurrent = failureIdle || index != activeIndex
        if changesCurrent {
            arrivalDwell = index == activeIndex + 1 ? activatedAt.map { max(0, requestedAt - $0) } : nil
            resetPagingRetry(); saveAndDeactivate(); failureIdle = false; playlist.index = index; pendingSnapshot = HMPlaybackSnapshot(); pendingSnapshot.state = .loading; emit(.currentItemChanged(currentItem)) }
        if retryFailed, let currentItem {
            networkFailures[currentItem] = nil
            let hadResolutionFailure = resolutionFailures.removeValue(forKey: currentItem) != nil
            let wasTerminal = terminalFailures.remove(currentItem) != nil
            if wasTerminal { currentNode?.release() }
            if hadResolutionFailure || wasTerminal { pendingSnapshot = HMPlaybackSnapshot(); pendingSnapshot.state = .loading }
        }
        requestedPageID = nil; failurePageID = nil; deferredFailureCommit = nil; requestTime = requestedAt; requestReason = reason
        prefetchSafe = false; prefetchIdentity = ""; proxy?.cancelPrefetch(); refreshWindow(); checkEnd(); scheduleFailedItemAdvance()
    }
    /// Requests a view-driven animated page move; activation waits until scrolling settles.
    @_spi(Benchmark) public func requestPage(at index: Int) {
        guard items.indices.contains(index), index != activeIndex else { return }
        requestedPageID = items[index].id; pageRequestID = UUID()
    }
    func commitPage(toID id: String, requestedAt: TimeInterval) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        // Native settle and SwiftUI's quiet fallback may both report this page.
        // A duplicate must not replace the original action clock during resolution.
        guard id != currentItem?.id else {
            requestedPageID = nil; failurePageID = nil; deferredFailureCommit = nil
            return
        }
        let failedMove = failurePageID == id
        if failedMove, feedIsTouching || partnerIsInteracting {
            deferredFailureCommit = (id, requestedAt)
            return
        }
        navigate(to: index, reason: failedMove ? "failed-item" : "swipe",
                 requestedAt: requestedAt, retryFailed: false)
    }
    func attachFeed() { feedSurfaces += 1 }
    func detachFeed() {
        feedSurfaces = max(0, feedSurfaces - 1)
        pageIsMoving = false; feedIsTouching = false
        if feedSurfaces == 0, let id = requestedPageID, failurePageID == id {
            commitPage(toID: id, requestedAt: ProcessInfo.processInfo.systemUptime)
        }
        scheduleFailedItemAdvance()
    }
    func setPageMoving(_ moving: Bool) {
        pageIsMoving = moving
        if !moving { scheduleFailedItemAdvance() }
    }
    /// Prepares transport before presenting a selected playlist index, preserving the request clock for analytics.
    @_spi(Benchmark) public func requestPlay(at index: Int, requestedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) async {
        guard items.indices.contains(index) else { return }
        let selected = items[index]
        if configuration.managesAudioSession { HMAudioSession.activatePlayback() }
        await prepareTransport()
        guard let index = items.firstIndex(of: selected), !ended else { return }
        wantsPlayback = true; navigate(to: index, requestedAt: requestedAt); isFeedVisible = true
    }
    private func saveAndDeactivate() {
        guard let node = currentNode, let item = currentItem else { return }
        resumePositions[item.id] = node.snapshot.currentTime
        node.deactivate(retainingPosition: configuration.restoresPlaybackPosition)
    }

    /// Loads the first page once, if a playlist source is assigned. Feed views call this automatically.
    public func start() async {
        guard !ended else { return }
        let firstStart = !hasStarted; hasStarted = true
        if playlistSource != nil, firstStart || items.isEmpty { await fetchNextPage() }
        refreshWindow()
    }
    /// Requests one page, resetting the automatic retry budget. Concurrent calls while loading do nothing.
    /// Failed pages retry automatically after 1, 2 and 4 seconds near the end, then stop until navigation or another explicit call.
    public func loadNextPage() async {
        guard !isLoadingPage, hasMoreContent, playlistSource != nil, !ended else { return }
        resetPagingRetry()
        await fetchNextPage()
    }
    private func resetPagingRetry() {
        pagingRetryTask?.cancel(); pagingRetryTask = nil
        pagingRetry = HMPagingRetry(); loadError = nil
    }
    private func resetPagingCursor() {
        cursorGeneration += 1; nextCursor = nil
        hasMoreContent = playlistSource != nil
        resetPagingRetry()
    }
    private func fetchNextPage() async {
        guard !isLoadingPage, hasMoreContent, let source = playlistSource, !ended,
              pagingRetry.canRetry(at: ProcessInfo.processInfo.systemUptime) else { return }
        let generation = pageGeneration, cursorVersion = cursorGeneration
        isLoadingPage = true
        defer {
            if generation == pageGeneration {
                isLoadingPage = false
                if loadTask == nil { checkEnd() }
                scheduleFailedItemAdvance()
            }
        }
        do {
            let page = try await source.loadPage(cursor: nextCursor)
            try Task.checkCancellation()
            guard generation == pageGeneration, cursorVersion == cursorGeneration, !ended else { return }
            let filtered = playlist.filterSourcePage(page.items)
            // Validate before the mutation path so a rejected page records one failure
            // and one error, just like a thrown source error.
            var validated = playlist
            try validated.append(filtered.items)
            guard appendItems(filtered.items, fromSource: true) else { return }
            let previousCursor = nextCursor
            nextCursor = page.nextCursor; hasMoreContent = page.nextCursor != nil && page.nextCursor != previousCursor
            resetPagingRetry()
            if !filtered.duplicates.isEmpty { emit(.sourcePageDuplicates(ids: filtered.duplicates)) }
        } catch is CancellationError { }
        catch {
            if generation == pageGeneration, cursorVersion == cursorGeneration, !ended {
                pagingRetry.failed(at: ProcessInfo.processInfo.systemUptime)
                report(.playlistSource(error.localizedDescription))
            }
        }
    }
    private func checkEnd() {
        guard !ended else { return }
        let remaining = max(0, items.count - activeIndex - 1)
        guard remaining <= max(0, configuration.lowWaterMark) else { nearingEndKey = ""; return }
        let key = "\(playlistRevision):\(activeIndex)"
        if currentItem != nil, key != nearingEndKey { nearingEndKey = key; emit(.nearingEnd(remaining: remaining)) }
        guard hasMoreContent, !isLoadingPage, loadTask == nil, !pagingRetry.exhausted else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard pagingRetry.canRetry(at: now) else {
            guard pagingRetryTask == nil else { return }
            let delay = pagingRetry.nextAttempt - now
            pagingRetryTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self else { return }
                pagingRetryTask = nil; checkEnd()
            }
            return
        }
        let token = UUID(); pageTaskID = token
        loadTask = Task { [weak self] in
            guard let self else { return }
            await fetchNextPage()
            if pageTaskID == token { loadTask = nil; checkEnd() }
        }
    }

    private func prepareTransport() async {
        guard !ended else { return }
        if let transportTask { await transportTask.value; return }
        transportTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let proxy { try await proxy.start(); return }
                let created = try HMCacheProxy(configuration: configuration)
                created.onEvent = { [weak self] event, item in self?.handle(event, item: item) }
                try await created.start()
                guard !ended else { _ = await created.finish(); return }
                proxy = created
            } catch { report(.playback("Cache transport: \(error.localizedDescription)")) }
        }
        await transportTask?.value
        transportTask = nil
    }
    private var windowItems: [HMMediaItem] {
        guard !failureIdle else { return [] }
        let resolved = max(0, min(32, configuration.resolveAhead))
        let warm = configuration.strategy == .S2 || configuration.prefetch.ahead > 0 ? configuration.warmOffsets : []
        return playlist.window(offsets: [0] + configuration.prefetch.windowOffsets + warm +
            (resolved > 0 ? Array(1...resolved) : []))
    }

    private func refreshWindow() {
        guard !ended else { return }
        if let currentItem, resolutions.cached(currentItem) == nil {
            pendingSnapshot.readinessTier = .resolving
            if terminalFailures.contains(currentItem) { pendingSnapshot.state = .failed }
        }
        updateInteractions()
        let window = windowItems
        resolutions.retain(Set(window))
        for (item, task) in resolutionTasks where !window.contains(item) { task.cancel(); resolutionTasks[item] = nil }
        let currentIDs = Set(items.map(\.id))
        resumePositions = resumePositions.filter { currentIDs.contains($0.key) }
        timelines = timelines.filter { items.contains($0.key) }
        engagements = engagements.filter { items.contains($0.key) }
        resolutionFailures = resolutionFailures.filter { items.contains($0.key) }
        pool.trim(keeping: Set(([currentItem].compactMap { $0 } + configuration.warmOffsets.compactMap { offset in
            let i = activeIndex + offset; return items.indices.contains(i) ? items[i] : nil
        }).compactMap { resolutions.cached($0) }))
        let playable = window.compactMap { resolutions.cached($0) }
        proxy?.retainWindow(playable)
        proxy?.retainPlaylist(items.compactMap { resolutions.cached($0) })
        guard isFeedVisible, currentItem != nil else { return }
        if proxy == nil {
            Task { [weak self] in guard let self else { return }; await prepareTransport(); guard !ended else { return }; refreshWindow() }
            return
        }
        refreshWindowAfterTransport()
        scheduleNetworkRetry()
    }
    private func refreshWindowAfterTransport() {
        guard !ended, isFeedVisible else { return }
        resolutionRetryTask?.cancel(); resolutionRetryTask = nil
        let mediaIDs = Set(playlist.window(offsets: [0] + (prefetchPlan?.windowOffsets ?? configuration.prefetch.windowOffsets) +
            configuration.warmOffsets).map(\.id))
        let retryTargets = networkRetryTargets
        for item in windowItems {
            let metadataOnly = item != currentItem && (!prefetchSafe || !mediaIDs.contains(item.id))
            let urgent = item == currentItem || item == items.dropFirst(activeIndex + 1).first
            if urgent { resolutions.promote(item) }
            guard !terminalFailures.contains(item), resolutions.cached(item, requireFormat: !metadataOnly) == nil, resolutionTasks[item] == nil,
                  resolutionFailures[item]?.canRetry(at: ProcessInfo.processInfo.systemUptime) != false,
                  networkFailures[item].map({ retryTargets.contains(item) && (!$0.nextAttempt.isFinite || $0.nextAttempt <= ProcessInfo.processInfo.systemUptime) }) != false else { continue }
            resolutionTasks[item] = Task(priority: urgent ? .userInitiated : .utility) { [weak self] in
                guard let self else { return }
                do {
                    let result = try await resolutions.resolve(item, using: resolver, metadataOnly: metadataOnly)
                    try Task.checkCancellation()
                    guard windowItems.contains(item), !ended else { return }
                    guard let url = result.url, ["file", "http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw HMPlayerError.unsupportedURL }
                    resolutionTasks[item] = nil; resolutionFailures[item] = nil; networkFailures[item] = nil
                    refreshWindow()
                } catch is CancellationError { }
                catch {
                    guard !Task.isCancelled, windowItems.contains(item), !ended else { return }
                    resolutionTasks[item] = nil
                    if HMNetworkFailure.isTransient(error) {
                        if currentItem == item { pendingSnapshot.state = .loading }
                        report(error as? HMPlayerError ?? .resolution(error.localizedDescription), item: item)
                        markNetworkFailure(item)
                        return
                    }
                    networkFailures[item] = nil
                    var failure = resolutionFailures[item] ?? HMResolutionRetry()
                    failure.failed(at: ProcessInfo.processInfo.systemUptime); resolutionFailures[item] = failure
                    let kind = error as? HMPlayerError ?? .resolution(error.localizedDescription)
                    if currentItem == item {
                        pendingSnapshot.state = failure.attempts >= HMResolutionRetry.maximumAttempts ? .failed : .loading
                        pendingSnapshot.errorDescription = kind.localizedDescription
                    }
                    report(kind, item: item)
                    if failure.attempts >= HMResolutionRetry.maximumAttempts { markTerminalFailure(item) }
                    scheduleResolutionRetry()
                }
            }
        }
        scheduleResolutionRetry(); resumeActive(); updatePrefetch()
    }
    private func scheduleResolutionRetry() {
        guard isFeedVisible, !ended else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let deadlines = windowItems.compactMap { item -> TimeInterval? in
            guard resolutionTasks[item] == nil, let retry = resolutionFailures[item], retry.attempts < HMResolutionRetry.maximumAttempts else { return nil }
            return retry.nextAttempt
        }
        guard let deadline = deadlines.min() else { return }
        resolutionRetryTask?.cancel()
        resolutionRetryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.01, deadline - now))) } catch { return }
            self?.refreshWindow()
        }
    }
    private func resumeActive() {
        guard isFeedVisible, !ended, let original = currentItem, !terminalFailures.contains(original),
              networkFailures[original].map({ $0.nextAttempt.isFinite }) != true, let item = resolutions.cached(original), let url = item.url else { return }
        guard ["file", "http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        let node = pool.node(for: item, protecting: [item.id], playbackURL: proxy?.url(for: item))
        node.onBufferChanged = { [weak self] in self?.updatePrefetch() }
        node.setMuted(isMuted)
        analytics.attach(playerLayer: node.playerLayer, playerKey: node.id, item: item)
        if !node.isActive {
            proxy?.markPlayed(item)
            node.activate(startingAt: configuration.restoresPlaybackPosition ? resumePositions[item.id] : nil,
                          requestedAt: requestTime, reason: requestReason, cachedBytes: proxy?.cachedByteCount(for: item) ?? 0)
            if !wantsPlayback { node.pause() }
        } else if wantsPlayback && node.snapshot.state == .paused { node.play() }
    }
    private func updatePrefetch(force: Bool = false) {
        guard isFeedVisible, !ended, let node = currentNode, node.isActive, let item = currentItem else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let t = configuration.adaptiveThresholds
        let dangerous = node.snapshot.state == .buffering || !node.snapshot.bufferedAhead.isFinite ||
            node.snapshot.bufferedAhead < max(nonnegative(t.safetyBufferSeconds), nonnegative(configuration.prefetch.startThreshold) * 0.5)
        // Evaluate on the existing 100ms buffer ticks at most four times/sec;
        // safety transitions bypass the cadence and are applied immediately.
        guard force || now - lastDecisionAt >= 0.25 || (prefetchSafe && dangerous) else { return }
        lastDecisionAt = now
        let inputs = HMPrefetchInputs(throughputBytesPerSecond: measurements.throughput,
            latencySeconds: measurements.latency, readyHitRate: measurements.hitRate, dwellSeconds: measurements.dwell,
            bufferedAheadSeconds: node.snapshot.bufferedAhead,
            remainingSeconds: node.snapshot.duration > 0 ? max(0, node.snapshot.duration - node.snapshot.currentTime) : nil,
            isStalling: node.snapshot.state == .buffering, wasPaused: !prefetchSafe,
            elapsedOnItemSeconds: max(0, now - (activatedAt ?? now)), previousPlan: prefetchPlan)
        var plan = (configuration.adaptive ? prefetchPolicy.decide(inputs, configuration: configuration) :
                    HMAdaptivePrefetchPolicy().decide(inputs, configuration: configuration)).clamped(to: configuration)
        // The safety gate is enforced even for a custom provider. Fixed mode
        // preserves the existing benchmark threshold/hysteresis and S2 control.
        let safety = HMAdaptivePrefetchPolicy().decide(inputs, configuration: configuration).paused
        if configuration.adaptive { plan.paused = plan.paused || safety }
        else {
            plan.paused = configuration.strategy != .S2 && !HMBufferSafety.isSafe(ahead: inputs.bufferedAheadSeconds,
                remaining: inputs.remainingSeconds ?? 0, hasDuration: inputs.remainingSeconds != nil,
                threshold: nonnegative(configuration.prefetch.startThreshold), wasSafe: prefetchSafe)
            plan.paused = plan.paused || inputs.isStalling
        }
        if plan.paused && !plan.reason.contains("buffer-safety") && !plan.reason.contains("stall") {
            plan.reason += inputs.isStalling ? "+stall" : "+buffer-safety"
        }
        plan = plan.clamped(to: configuration)
        let changed = prefetchPlan != plan
        let bitrateChanged = pool.configuration.startupPeakBitRate != plan.startingBitRate
        let recovered = !prefetchSafe && !plan.paused
        prefetchSafe = !plan.paused
        if changed {
            prefetchPlan = plan
            analytics.recordPrefetchDecision(inputs: inputs, plan: plan, item: item,
                policy: configuration.adaptive ? String(reflecting: type(of: prefetchPolicy)) : "fixed")
            var effective = configuration; effective.startupPeakBitRate = plan.startingBitRate
            pool.configuration = effective; pool.applyConfiguration()
            if bitrateChanged { for node in pool.nodes { node.applyStartingBitRate(plan.startingBitRate) } }
        }
        let deferred = inputs.elapsedOnItemSeconds < plan.startAfterSeconds
        let warmOffsets = plan.keepReadyPlayer && !deferred ? configuration.warmOffsets : []
        let warmItems = warmOffsets.compactMap { offset -> HMMediaItem? in
            let i = activeIndex + offset; return items.indices.contains(i) ? resolutions.cached(items[i]) : nil
        }
        pool.trim(keeping: Set([resolutions.cached(item)].compactMap { $0 } + warmItems))
        if plan.paused || deferred {
            if !prefetchIdentity.isEmpty { proxy?.cancelPrefetch(); prefetchIdentity = "" }
            if recovered && !plan.paused { refreshWindowAfterTransport() }
            return
        }
        let data = plan.windowOffsets.compactMap { offset -> HMMediaItem? in
            let i = activeIndex + offset; return items.indices.contains(i) ? resolutions.cached(items[i]) : nil
        }
        let identity = plan.workIdentity + "|" + item.id + "|" + data.map { $0.id + ($0.url?.absoluteString ?? "") }.joined(separator: "|")
        guard identity != prefetchIdentity else { if recovered { refreshWindowAfterTransport() }; return }
        prefetchIdentity = identity
        for item in warmItems where pool.existingNode(for: item) == nil {
            let warm = pool.node(for: item, protecting: Set([currentItem?.id].compactMap { $0 }), playbackURL: proxy?.url(for: item))
            warm.onBufferChanged = { [weak self] in self?.updatePrefetch() }; warm.setMuted(isMuted)
        }
        proxy?.prefetch(data, keeping: windowItems.compactMap { resolutions.cached($0) }, plan: plan)
        if recovered { refreshWindowAfterTransport() }
    }
    private func updateInteractions() {
        let current = isFeedVisible ? currentItem : nil
        let next = isFeedVisible && items.indices.contains(activeIndex + 1) ? items[activeIndex + 1] : nil
        let keep = Set([current, next].compactMap { $0 })
        for item in Set([interactionCurrent, interactionNext].compactMap { $0 }) where !keep.contains(item) { interactions.didLeave(item) }
        if current != interactionCurrent, let current { interactions.didBecomeCurrent(current) }
        if next != interactionNext, let next { interactions.willBecomeNext(next) }
        interactionCurrent = current; interactionNext = next
    }
    /// Read-only playback snapshot for an entry. Unprepared entries report idle.
    public func snapshot(for item: HMMediaItem) -> HMPlaybackSnapshot { resolutions.cached(item).flatMap { pool.existingNode(for: $0) }?.snapshot ?? (currentItem == item ? pendingSnapshot : HMPlaybackSnapshot()) }
    /// Clock-indexed overlay data. Network session lifecycle belongs to the interaction hooks, not this accessor.
    public func timeline(for item: HMMediaItem) -> HMStreamTimeline {
        let entry = items.first { $0.id == item.id } ?? item
        if let existing = timelines[entry] { return existing }
        let created = interactions.timeline(for: resolutions.cached(entry) ?? entry); timelines[entry] = created; return created
    }
    /// Observable chat, polls, reactions and actions for an entry, on its media clock. Created once per
    /// entry and kept while it stays in the playlist; actions default to the entry's current playback time.
    public func engagement(for item: HMMediaItem) -> HMEngagement {
        let entry = items.first { $0.id == item.id } ?? item
        if let existing = engagements[entry] { return existing }
        let display = resolutions.cached(entry) ?? entry
        let created = HMEngagement(item: display, timeline: timeline(for: entry), source: interactions) { [weak self] in
            self?.snapshot(for: entry).currentTime ?? 0
        }
        // Entries outside the playlist are served but not cached, matching `timeline(for:)`'s lookup.
        if items.contains(entry) { engagements[entry] = created }
        interactions.engagementDidLoad(created)
        return created
    }
    var currentNode: HMPlayerNode? { currentItem.flatMap { resolutions.cached($0) }.flatMap { pool.existingNode(for: $0) } }
    func node(for item: HMMediaItem) -> HMPlayerNode? { resolutions.cached(item).flatMap { pool.existingNode(for: $0) } }
    func displayItem(_ item: HMMediaItem) -> HMMediaItem { resolutions.cached(item, requireFormat: false) ?? item }
    /// Toggles current playback; useful for tap overlays.
    public func togglePlayPause() { wantsPlayback ? pause() : play() }
    /// Toggles global mute.
    public func toggleMute() { isMuted.toggle() }
    /// Seeks to a fraction of the current VOD duration.
    public func seek(toProgress progress: Double) { guard progress.isFinite else { report(.invalidSeek); return }; seek(to: snapshot.duration * min(1, max(0, progress))) }
    private func pauseAll() {
        proxy?.cancelPrefetch(); prefetchSafe = false; prefetchIdentity = ""
        for node in pool.nodes where node.isActive { node.pause() }
        resolutionRetryTask?.cancel(); resolutionRetryTask = nil
        networkRetryTask?.cancel(); networkRetryTask = nil
        // Visibility pauses media work, but in-flight URL/poster resolution survives.
        updateInteractions()
    }
    /// Ends a benchmark session, drains transport accounting and emits runEnd. The player is terminal afterwards.
    @_spi(Benchmark) public func finishRun() async {
        guard !ended else { return }
        ended = true; stopWork()
        let item = currentItem
        for node in pool.nodes { node.release() }
        await transportTask?.value
        let waste = await proxy?.finish() ?? 0
        if let item { analytics.emit(HMPlaybackEvent(kind: .runEnd, itemID: item.id, metrics: ["wasted_prefetch_bytes": Double(waste)]), item: item) }
        finishSubscribers()
    }
    /// Releases players, interaction sessions and asynchronous work. Call when the host is permanently dismissed.
    public func teardown() {
        ended = true; stopWork()
        if let proxy { Task { _ = await proxy.finish() } }
        for node in pool.nodes { analytics.detach(playerKey: node.id) }; pool.releaseAll()
        finishSubscribers()
        if configuration.managesAudioSession { HMAudioSession.deactivate() }
    }
    private func stopWork() {
        failureAdvanceTask?.cancel(); failureAdvanceTask = nil
        interactionTimeoutTask?.cancel(); interactionTimeoutTask = nil
        networkRetryTask?.cancel(); networkRetryTask = nil
        connectivityMonitor?.cancel(); connectivityMonitor = nil
        pageGeneration += 1; loadTask?.cancel(); isLoadingPage = false
        pagingRetryTask?.cancel(); pagingRetryTask = nil
        resolutionRetryTask?.cancel(); resolutionRetryTask = nil
        resolutions.cancelAll(); for task in resolutionTasks.values { task.cancel() }; resolutionTasks.removeAll()
        for item in Set([interactionCurrent, interactionNext].compactMap { $0 }) { interactions.didLeave(item) }
        interactionCurrent = nil; interactionNext = nil; proxy?.cancelPrefetch()
    }
    private func finishSubscribers() { for continuation in subscribers.values { continuation.finish() }; subscribers.removeAll() }
    private func applyConfiguration() {
        guard !ended else { return }
        var effective = configuration
        if let plan = prefetchPlan { effective.startupPeakBitRate = plan.clamped(to: configuration).startingBitRate }
        pool.configuration = effective
        for node in pool.nodes.dropFirst(max(1, min(4, configuration.poolSize))) { analytics.detach(playerKey: node.id) }
        pool.resize(to: configuration.poolSize); proxy?.configuration = configuration; prefetchSafe = false
        prefetchIdentity = ""; lastDecisionAt = -Double.infinity
        refreshWindow(); checkEnd(); scheduleFailedItemAdvance()
    }
    private func handle(_ event: HMPlaybackEvent, item: HMMediaItem) {
        if event.kind == .transferSample {
            measurements.transfer(bytes: event.metrics["sample_bytes"] ?? 0, seconds: event.metrics["receive_s"] ?? 0,
                ttfb: event.metrics["ttfb_s"], alpha: configuration.adaptiveThresholds.ewmaAlpha)
        }
        let nextArrival = event.kind == .viewStart && arrivalDwell != nil
        if event.kind == .viewStart {
            if let dwell = arrivalDwell {
                measurements.arrival(hit: ["warmPlayer", "cachedBytes"].contains(event.properties["readiness_tier"] ?? ""),
                    dwell: dwell, alpha: configuration.adaptiveThresholds.ewmaAlpha)
            }
            arrivalDwell = nil; activatedAt = event.monotonicTime; lastDecisionAt = -Double.infinity
        }
        var metrics = event.metrics
        if event.kind == .viewStart {
            metrics["next_arrival"] = nextArrival ? 1 : 0
            metrics["ready_by_swipe_hit"] = ["warmPlayer", "cachedBytes"].contains(event.properties["readiness_tier"] ?? "") ? 1 : 0
        }
        if event.kind == .viewStart || event.kind == .firstFrame { metrics["live_player_count"] = Double(pool.nodes.count); metrics["memory_bytes"] = HMMemorySample.footprint() }
        analytics.emit(HMPlaybackEvent(kind: event.kind, itemID: event.itemID, timestamp: event.timestamp,
            monotonicTime: event.monotonicTime, position: event.position, metrics: metrics, properties: event.properties), item: item)
        let entry = items.first { $0.id == item.id } ?? item
        switch event.kind {
        case .preloadReady:
            networkFailures[entry] = nil
            emit(.itemReady(entry))
        case .firstFrame: emit(.firstFrame(entry, ttff: (event.metrics["ttff_ms"] ?? 0) / 1000, readiness: currentNode?.snapshot.readinessTier ?? .cold))
        case .rebufferStart: emit(.stallStarted(entry)); updatePrefetch(force: true)
        case .rebufferEnd: emit(.stallEnded(entry)); updatePrefetch(force: true)
        case .error, .transportError:
            report(.playback(event.properties["error_message"] ?? event.properties["message"] ?? "Playback failed"), item: entry)
            // Transport errors can recover via the node's direct-URL fallback.
            // Only the native terminal error marks the entry unplayable.
            if event.kind == .error, resolutions.cached(entry) == item {
                let raw = NSError(domain: event.properties["error_domain"] ?? "", code: Int(event.properties["error_code"] ?? "") ?? 0)
                if event.properties["transient_network"] == "true" || HMNetworkFailure.isTransient(raw) {
                    markNetworkFailure(entry)
                } else { markTerminalFailure(entry) }
            }
        default: break
        }
    }
    /// While an error is transient, only current and next retry. Farther window entries keep their
    /// failure record and retry once navigation brings them into this pair, so a recovering server
    /// sees at most two requests per client rather than the whole prefetch window at once.
    private var networkRetryTargets: Set<HMMediaItem> {
        guard !failureIdle, let currentItem else { return [] }
        return Set([currentItem] + (items.indices.contains(activeIndex + 1) ? [items[activeIndex + 1]] : []))
    }
    private func markNetworkFailure(_ item: HMMediaItem) {
        terminalFailures.remove(item)
        var retry = networkFailures[item] ?? HMNetworkRetry()
        retry.failed(at: ProcessInfo.processInfo.systemUptime)
        networkFailures[item] = retry
        scheduleNetworkRetry()
    }
    private func scheduleNetworkRetry() {
        networkRetryTask?.cancel(); networkRetryTask = nil
        guard !ended, isFeedVisible else { return }
        let targets = networkRetryTargets
        guard let deadline = networkFailures.filter({ targets.contains($0.key) }).values.map(\.nextAttempt).filter(\.isFinite).min() else { return }
        networkRetryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.01, deadline - ProcessInfo.processInfo.systemUptime))) } catch { return }
            self?.retryNetworkFailures()
        }
    }
    private func retryNetworkFailures() {
        guard !ended, isFeedVisible else { return }
        let now = ProcessInfo.processInfo.systemUptime, targets = networkRetryTargets
        for item in Array(networkFailures.keys) where targets.contains(item) && networkFailures[item]!.nextAttempt <= now {
            networkFailures[item]?.nextAttempt = .infinity
            if let node = node(for: item), node.snapshot.state == .failed {
                node.release()
                if currentItem == item { pendingSnapshot.state = .loading }
            }
        }
        refreshWindow()
    }
    // Called by the owned NWPathMonitor; internal for deterministic reconnect coverage.
    func connectivityChanged(satisfied: Bool) {
        guard !ended else { return }
        let returned = lastPathSatisfied == false && satisfied
        lastPathSatisfied = satisfied
        guard returned else { return }
        terminalFailures.removeAll(); resolutionFailures.removeAll()
        for item in Array(networkFailures.keys) { networkFailures[item]?.nextAttempt = 0 }
        if failureIdle, playlist.current != nil {
            failureIdle = false; pendingSnapshot = HMPlaybackSnapshot(); pendingSnapshot.state = .loading
            emit(.currentItemChanged(currentItem))
        }
        if currentNode?.snapshot.state == .failed { currentNode?.release() }
        retryNetworkFailures()
    }
    private func markTerminalFailure(_ item: HMMediaItem) {
        networkFailures[item] = nil
        terminalFailures.insert(item)
        scheduleFailedItemAdvance()
    }
    private func scheduleFailedItemAdvance() {
        guard !ended, failureAdvanceTask == nil else { return }
        failureAdvanceTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            failureAdvanceTask = nil
            advancePastFailure()
        }
    }
    private func advancePastFailure() {
        if let deferred = deferredFailureCommit, !isInteracting {
            deferredFailureCommit = nil
            commitPage(toID: deferred.id, requestedAt: ProcessInfo.processInfo.systemUptime)
            return
        }
        guard !ended, configuration.failedItemPolicy == .skip, !isInteracting, !pageIsMoving,
              requestedPageID == nil, let failed = currentItem ?? (failureIdle ? playlist.current : nil),
              terminalFailures.contains(failed) else { return }
        let index = playlist.index
        let forward = Array(items.indices.dropFirst(index + 1))
        // A late page may contain the next playable entry; do not retreat while it is outstanding.
        // Once the paging retry budget is exhausted no page is coming without navigation or an
        // explicit loadNextPage(), so fall back to the previous entry instead of waiting forever.
        if !forward.contains(where: { !terminalFailures.contains(items[$0]) }), isLoadingPage || (hasMoreContent && !pagingRetry.exhausted) {
            checkEnd()
            return
        }
        let candidates = forward + Array(items.indices.prefix(index).reversed())
        guard let next = candidates.first(where: { !terminalFailures.contains(items[$0]) }) else {
            guard !failureIdle else { return }
            saveAndDeactivate(); failureIdle = true; pendingSnapshot = HMPlaybackSnapshot()
            proxy?.cancelPrefetch(); pool.releaseAll(); refreshWindow()
            emit(.currentItemChanged(nil))
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if feedSurfaces > 0, !failureIdle {
            requestPage(at: next); failurePageID = items[next].id
        } else {
            failurePageID = items[next].id
            commitPage(toID: items[next].id, requestedAt: now)
        }
    }
    private func emit(_ event: HMPlayerEvent) { lastEvent = event; for continuation in subscribers.values { continuation.yield(event) } }
    private func report(_ kind: HMPlayerError, item: HMMediaItem? = nil) { loadError = kind.localizedDescription; emit(.error(item: item, kind: kind)) }
}
#endif
