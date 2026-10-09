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
    public var activeIndex: Int { playlist.index }
    /// Last committed current entry, or nil while idle.
    public var currentItem: HMMediaItem? { playlist.current }
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
        didSet { pageGeneration += 1; loadTask?.cancel(); loadTask = nil; pageTaskID = UUID(); isLoadingPage = false; resetPagingCursor() }
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

    var requestedPageID: String?
    var requestedPageIndex: Int? { requestedPageID.flatMap { id in items.firstIndex { $0.id == id } } }
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
        self.interactions = interactions ?? HMMockInteractionSource()
        self.analytics = analytics ?? HMAnalyticsHub(); isMuted = configuration.startsMuted
        pool = HMPlayerPool(configuration: configuration)
        pool.onEvent = { [weak self] event, item in self?.handle(event, item: item) }
        pool.willRecycle = { [weak self] node, item in self?.analytics.videoChange(playerKey: node.id, item: item) }
        for node in pool.nodes { node.onBufferChanged = { [weak self] in self?.updatePrefetch() } }
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
        playlist = result; loadError = nil; playlistRevision += 1
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
        refreshWindow(); checkEnd()
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
    private func navigate(to index: Int, reason: String = "play", requestedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard items.indices.contains(index), !ended else { return }
        if index != activeIndex {
            arrivalDwell = index == activeIndex + 1 ? activatedAt.map { max(0, requestedAt - $0) } : nil
            resetPagingRetry(); saveAndDeactivate(); playlist.index = index; pendingSnapshot = HMPlaybackSnapshot(); pendingSnapshot.state = .loading; emit(.currentItemChanged(currentItem)) }
        if let currentItem { resolutionFailures[currentItem] = nil }
        requestedPageID = nil; requestTime = requestedAt; requestReason = reason
        prefetchSafe = false; prefetchIdentity = ""; proxy?.cancelPrefetch(); refreshWindow(); checkEnd()
    }
    /// Requests a view-driven animated page move; activation waits until scrolling settles.
    @_spi(Benchmark) public func requestPage(at index: Int) {
        guard items.indices.contains(index), index != activeIndex else { return }
        requestedPageID = items[index].id; pageRequestID = UUID()
    }
    func commitPage(toID id: String, requestedAt: TimeInterval) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        navigate(to: index, reason: "swipe", requestedAt: requestedAt)
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
        let resolved = max(0, min(32, configuration.resolveAhead))
        let warm = configuration.strategy == .S2 || configuration.prefetch.ahead > 0 ? configuration.warmOffsets : []
        return playlist.window(offsets: [0] + configuration.prefetch.windowOffsets + warm +
            (resolved > 0 ? Array(1...resolved) : []))
    }

    private func refreshWindow() {
        guard !ended else { return }
        updateInteractions()
        let window = isFeedVisible ? windowItems : []
        resolutions.retain(Set(window))
        for (item, task) in resolutionTasks where !window.contains(item) { task.cancel(); resolutionTasks[item] = nil }
        let currentIDs = Set(items.map(\.id))
        resumePositions = resumePositions.filter { currentIDs.contains($0.key) }
        timelines = timelines.filter { items.contains($0.key) }
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
    }
    private func refreshWindowAfterTransport() {
        guard !ended, isFeedVisible else { return }
        resolutionRetryTask?.cancel(); resolutionRetryTask = nil
        let mediaIDs = Set(playlist.window(offsets: [0] + (prefetchPlan?.windowOffsets ?? configuration.prefetch.windowOffsets) +
            configuration.warmOffsets).map(\.id))
        for item in windowItems {
            let metadataOnly = !mediaIDs.contains(item.id)
            guard item == currentItem || !configuration.adaptive || prefetchSafe else { continue }
            let urgent = item == currentItem || item == items.dropFirst(activeIndex + 1).first
            if urgent { resolutions.promote(item) }
            guard resolutions.cached(item, requireFormat: !metadataOnly) == nil, resolutionTasks[item] == nil,
                  resolutionFailures[item]?.canRetry(at: ProcessInfo.processInfo.systemUptime) != false else { continue }
            resolutionTasks[item] = Task(priority: urgent ? .userInitiated : .utility) { [weak self] in
                guard let self else { return }
                do {
                    let result = try await resolutions.resolve(item, using: resolver, metadataOnly: metadataOnly)
                    try Task.checkCancellation()
                    guard windowItems.contains(item), !ended else { return }
                    guard let url = result.url, ["file", "http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw HMPlayerError.unsupportedURL }
                    resolutionTasks[item] = nil; resolutionFailures[item] = nil
                    refreshWindow()
                } catch is CancellationError { }
                catch {
                    guard !Task.isCancelled, windowItems.contains(item), !ended else { return }
                    resolutionTasks[item] = nil
                    var failure = resolutionFailures[item] ?? HMResolutionRetry()
                    failure.failed(at: ProcessInfo.processInfo.systemUptime); resolutionFailures[item] = failure
                    let kind = error as? HMPlayerError ?? .resolution(error.localizedDescription)
                    if currentItem == item { pendingSnapshot.state = .failed; pendingSnapshot.errorDescription = kind.localizedDescription }
                    report(kind, item: item)
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
        guard isFeedVisible, !ended, let original = currentItem, let item = resolutions.cached(original), let url = item.url else { return }
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
            elapsedOnItemSeconds: max(0, now - (activatedAt ?? now)))
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
        let changed = prefetchPlan?.workIdentity != plan.workIdentity
        let recovered = !prefetchSafe && !plan.paused
        prefetchPlan = plan; prefetchSafe = !plan.paused
        analytics.emit(HMPlaybackEvent(kind: .prefetchDecision, itemID: item.id, metrics: [
            "plan_changed": changed ? 1 : 0, "budget_bytes": Double(plan.bytesPerItem),
            "items_ahead": Double(plan.itemsAhead), "items_behind": Double(plan.itemsBehind),
            "paused": plan.paused ? 1 : 0, "concurrency": Double(plan.concurrency),
            "starting_bitrate": plan.startingBitRate, "ready_hit_rate": measurements.hitRate ?? -1,
            "throughput_bytes_s": measurements.throughput ?? -1, "latency_s": measurements.latency ?? -1,
            "dwell_s": measurements.dwell ?? -1, "buffered_ahead_s": inputs.bufferedAheadSeconds
        ], properties: ["inputs": json(inputs), "plan": json(plan), "reason": plan.reason,
                         "policy": configuration.adaptive ? String(reflecting: type(of: prefetchPolicy)) : "fixed"]), item: item)
        var effective = configuration; effective.startupPeakBitRate = plan.startingBitRate
        pool.configuration = effective; pool.applyConfiguration()
        for node in pool.nodes { node.applyStartingBitRate(plan.startingBitRate) }
        let deferred = inputs.elapsedOnItemSeconds < plan.startAfterSeconds
        let warmOffsets = plan.keepReadyPlayer && !deferred ? configuration.warmOffsets : []
        let warmItems = warmOffsets.compactMap { offset -> HMMediaItem? in
            let i = activeIndex + offset; return items.indices.contains(i) ? resolutions.cached(items[i]) : nil
        }
        pool.trim(keeping: Set([resolutions.cached(item)].compactMap { $0 } + warmItems))
        if plan.paused || deferred {
            if plan.paused && configuration.adaptive {
                resolutions.retain(Set([currentItem].compactMap { $0 }))
                for (entry, task) in resolutionTasks where entry != currentItem { task.cancel(); resolutionTasks[entry] = nil }
            }
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
        resolutions.cancelAll()
        for task in resolutionTasks.values { task.cancel() }; resolutionTasks.removeAll()
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
        pool.configuration = configuration
        for node in pool.nodes.dropFirst(max(1, min(4, configuration.poolSize))) { analytics.detach(playerKey: node.id) }
        pool.resize(to: configuration.poolSize); proxy?.configuration = configuration; prefetchSafe = false
        prefetchIdentity = ""; lastDecisionAt = -Double.infinity
        refreshWindow(); checkEnd()
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
        case .preloadReady: emit(.itemReady(entry))
        case .firstFrame: emit(.firstFrame(entry, ttff: (event.metrics["ttff_ms"] ?? 0) / 1000, readiness: currentNode?.snapshot.readinessTier ?? .cold))
        case .rebufferStart: emit(.stallStarted(entry)); updatePrefetch(force: true)
        case .rebufferEnd: emit(.stallEnded(entry)); updatePrefetch(force: true)
        case .error, .transportError: report(.playback(event.properties["error_message"] ?? event.properties["message"] ?? "Playback failed"), item: entry)
        default: break
        }
    }
    private func emit(_ event: HMPlayerEvent) { lastEvent = event; for continuation in subscribers.values { continuation.yield(event) } }
    private func report(_ kind: HMPlayerError, item: HMMediaItem? = nil) { loadError = kind.localizedDescription; emit(.error(item: item, kind: kind)) }
}
#endif
