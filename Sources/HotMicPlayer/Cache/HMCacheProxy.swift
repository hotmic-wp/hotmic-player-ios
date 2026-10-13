#if canImport(Network) && !os(macOS)
import Foundation
import Network

/// One loopback HTTP transport for MP4 and HLS. Bound exclusively to loopback,
/// opaque routes, bounded upstream ranges, no URLSession implicit disk cache.
actor HMCacheTransport {
    struct Route { let url: URL; let item: HMMediaItem }
    struct Transfer {
        let data: Data; let total: Int; let mime: String; let base: URL; let start: Int; let cost: Int
        init(data: Data, total: Int, mime: String, base: URL, start: Int, cost: Int = 0) {
            self.data = data; self.total = total; self.mime = mime; self.base = base; self.start = start; self.cost = cost
        }
    }
    private var startup: Task<Bool, Never>?
    private var playlistOwners: Set<String> = []
    private var listener: NWListener?
    private var listenerID = UUID()
    private var startWaiters: [CheckedContinuation<Bool, Never>] = []
    private var disabled = false
    private var previousPort: UInt16 = 0
    nonisolated let state: HMProxyState
    private let queue = DispatchQueue(label: "com.hotmic.cache.http")
    private let cache: HMDiskCache
    private var port: UInt16 = 0
    private var isFinishing = false
    private var activePlaybackItem: HMMediaItem?
    private var playbackUrgent = true
    private var priorityItem: HMMediaItem?
    /// The one item whose explicit prefix may run while playback is urgent.
    private var admittedItem: HMMediaItem?
    private var priorityWaiters: [UUID: (HMMediaItem, CheckedContinuation<Void, Error>)] = [:]
    private var retainedItems: [HMMediaItem] = []
    private var resourceOwners: [String: Set<String>] = [:]
    private var inFlightResources: [String: Int] = [:]
    private var retiredWaste = 0
    private enum BudgetError: Error { case exhausted, rangeUnsupported }
    private enum NativeTransportFallback: Error { case rangeUnsupported }
    private struct Allocation { let count: Int; let owner: HMMediaItem.MediaIdentity? }
    private var speculativeReceived: [HMMediaItem.MediaIdentity: Int] = [:]
    private var reservedSpeculative: [HMMediaItem.MediaIdentity: Int] = [:]
    private var progressAllowed = true
    private var activationWaiters: [UUID: (HMMediaItem, CheckedContinuation<Void, Error>)] = [:]
    private var budgetWaiters: [UUID: (HMMediaItem, CheckedContinuation<Void, Error>)] = [:]
    private struct StreamState { var cursor: Int; var buffer = Data(); let total: Int; let mime: String; let base: URL; let speculative: Bool }
    private var streams: [UUID: StreamState] = [:]
    private var eventDelivery: Task<Void, Never>?
    private var connections: [UUID: NWConnection] = [:]
    private var responseTasks: [UUID: Task<Void, Never>] = [:]
    private var responseItems: [UUID: HMMediaItem] = [:]
    private struct PrefixWork {
        let token: UUID
        let item: HMMediaItem
        let task: Task<Void, Never>
    }
    private var prefixWork: [HMMediaItem.MediaIdentity: PrefixWork] = [:] { didSet { publishPrefixes() } }
    /// A prefix waiting for a slot (often behind a cancelled one still draining) is still the player's.
    private var prefixQueue: [HMMediaItem] = [] { didSet { publishPrefixes() } }
    /// Prefixes whose item became current mid-download: the resource in flight lands for playback, then the prefix stops.
    private var winding: Set<HMMediaItem.MediaIdentity> = []
    /// Explicit prefix downloads in flight per resource, and the playback reads waiting on them.
    private var prefetchFetching: [String: Int] = [:]
    private var downloadingResources: Set<String> = []
    private var resourceHolders: [String: HMMediaItem] = [:]
    private var nativeResourceConnections: [String: UUID] = [:]
    private var metadataPrefixResources: Set<String> = []
    private var resourceWaiters: [UUID: (key: String, item: HMMediaItem, continuation: CheckedContinuation<Void, Error>)] = [:]
    private var parkedPrefixes: Set<HMMediaItem.MediaIdentity> = []
    private var prefixWaiters: [HMMediaItem.MediaIdentity: (UUID, CheckedContinuation<Void, Error>)] = [:]
    private var prefixOrder: [HMMediaItem.MediaIdentity] = []
    private var prefixPlan: HMPrefetchPlan?
    private var prefixBudget = ""
    private var workEpoch = HMPrefetchEpoch()
    private var generation: Int { workEpoch.generation }
    private var prefetched: [String: String] = [:]
    private var exhaustedPrefixes: [String: String] = [:]
    private var prefetchedNetwork: [String: Int] = [:]
    private var prefetchRanges: [String: [HMByteRange]] = [:]
    private var playedRanges: [String: [HMByteRange]] = [:]
    private var warmDeliveries: [HMMediaItem.MediaIdentity: [String: [HMByteRange]]] = [:]
    private var retiringPrefetch: [UUID: Task<Void, Never>] = [:]
    private var playlists = HMPlaylistMemory<Transfer>()
    private(set) var cachedBytes: [String: Int] = [:]
    var configuration: HMPlayerConfiguration
    var onEvent: (@MainActor @Sendable (HMPlaybackEvent, HMMediaItem) -> Void)?

    init(configuration: HMPlayerConfiguration, directory: URL? = nil) throws {
        self.configuration = configuration
        state = HMProxyState(signingParameters: configuration.volatileSigningQueryParameters)
        let folder = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("HotMicPlayer-v1")
        cache = HMDiskCache.shared(directory: folder, capacity: configuration.cacheCapacityBytes)
    }
    func setEventHandler(_ handler: @escaping @MainActor @Sendable (HMPlaybackEvent, HMMediaItem) -> Void) { onEvent = handler }
    func updateConfiguration(_ config: HMPlayerConfiguration) async {
        let previous = configuration
        let signingChanged = previous.volatileSigningQueryParameters != config.volatileSigningQueryParameters
        if signingChanged { warmDeliveries.removeAll() }
        let changesWorkBudget = signingChanged || previous.strategy != config.strategy || previous.adaptive != config.adaptive ||
            previous.prefetch.bytesPerItem != config.prefetch.bytesPerItem || previous.prefetch.secondsPerItem != config.prefetch.secondsPerItem ||
            previous.startupPeakBitRate != config.startupPeakBitRate || previous.cacheCapacityBytes != config.cacheCapacityBytes ||
            (previous.maxPrefetchConcurrency == 0) != (config.maxPrefetchConcurrency == 0)
        configuration = config; state.configure(signingParameters: config.volatileSigningQueryParameters)
        if changesWorkBudget { cancelPrefetch() }
        if config.strategy.usesDataCache { await cache.configure(capacity: config.cacheCapacityBytes, pinned: Set(retainedItems.compactMap(\.url).map { key($0) })) }
    }
    func start() async -> Bool {
        if state.port != 0 { return true }
        if let startup { return await startup.value }
        let task = Task { await performStart() }; startup = task
        let ready = await task.value; startup = nil; return ready
    }
    private func performStart() async -> Bool {
        guard !isFinishing, !disabled else { return false }
        if port != 0 { return true }
        let ready = await withCheckedContinuation { c in
            startWaiters.append(c)
            guard listener == nil else { return }
            let identifier = UUID(); listenerID = identifier
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: previousPort) ?? .any)
                let created = try NWListener(using: parameters); listener = created
                created.stateUpdateHandler = { [weak self] value in Task { await self?.listenerState(value, identifier: identifier) } }
                created.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
                created.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 1) { [weak self] in Task { await self?.startTimedOut(identifier) } }
            } catch { resolveStart(false) }
        }
        guard ready else { return false }
        // Detect host ATS policy rather than requiring an app exception.
        do {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
            request.httpMethod = "HEAD"; request.timeoutInterval = 1
            let (_, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.cannotConnectToHost) }
        } catch {
            disabled = (error as NSError).code == NSURLErrorAppTransportSecurityRequiresSecureConnection
            listener?.cancel(); listener = nil; port = 0; state.setPort(0)
            return false
        }
        if configuration.strategy.usesDataCache { await cache.configure(capacity: configuration.cacheCapacityBytes, pinned: []) }
        cachedBytes = await cache.sizes(); state.setBytes(cachedBytes)
        guard !isFinishing, port != 0 else { return false }
        state.setPort(port)
        return true
    }
    private func resolveStart(_ ready: Bool) {
        if !ready { listener?.cancel(); listener = nil; port = 0; state.setPort(0); cancelPrefetch() }
        let waiters = startWaiters; startWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: ready) }
    }
    private func listenerState(_ value: NWListener.State, identifier: UUID) {
        guard listenerID == identifier else { return }
        switch value {
        case .ready:
            port = listener?.port?.rawValue ?? 0; previousPort = port; resolveStart(port != 0)
        case .failed: previousPort = 0; resolveStart(false)
        case .cancelled: resolveStart(false)
        default: break
        }
    }
    #if DEBUG
    func interruptListenerForTesting() { listener?.cancel() }
    #endif
    private func startTimedOut(_ identifier: UUID) { if identifier == listenerID, port == 0 { resolveStart(false) } }
    nonisolated func url(for item: HMMediaItem) -> URL? {
        guard let url = item.url else { return nil }
        guard !url.isFileURL else { return url }
        if state.port == 0 { Task { _ = await start() } }
        return state.url(url, item: item)
    }
    private func proxyURL(_ url: URL, item: HMMediaItem) -> URL { state.url(url, item: item) }
    private func identity(_ item: HMMediaItem) -> HMMediaItem.MediaIdentity {
        item.mediaIdentity(ignoring: configuration.volatileSigningQueryParameters)
    }
    private func key(_ url: URL) -> String { HMCacheKey.canonical(url, ignoring: configuration.volatileSigningQueryParameters) }
    func retainWindow(_ items: [HMMediaItem]) async {
        trimWindow(items)
        await cache.configure(capacity: configuration.cacheCapacityBytes, pinned: Set(items.compactMap(\.url).map { key($0) }))
    }
    private func trimWindow(_ items: [HMMediaItem]) {
        retainedItems = items
        let media = Set(items.map(identity))
        speculativeReceived = speculativeReceived.filter { media.contains($0.key) || reservedSpeculative[$0.key, default: 0] > 0 }
        prefixQueue.removeAll { !media.contains(identity($0)) }
        for identity in Array(prefixWork.keys) where !media.contains(identity) { cancelPrefix(identity) }
        for (id, item) in responseItems where !items.contains(where: { $0.hasSameMedia(as: item, ignoring: configuration.volatileSigningQueryParameters) }) { close(id, reason: "outside-window") }
        warmDeliveries = warmDeliveries.filter { media.contains($0.key) }
        let retained = Set(items.compactMap(\.url).map { key($0) })
        // Completed resources can be folded into one waste counter as soon as
        // their route leaves the window. Active/canceling requests retain their
        // accounting until completion and are revisited on the next commit.
        let activeKeys = Set(state.allURLs().map { key($0) }).union(inFlightResources.keys)
        for resource in Array(resourceOwners.keys) where !activeKeys.contains(resource) && resourceOwners[resource, default: []].isDisjoint(with: retained) && prefixWork.isEmpty && retiringPrefetch.isEmpty {
            retiredWaste += max(0, (prefetchedNetwork.removeValue(forKey: resource) ?? 0) - HMRangeCoverage.overlap(prefetchRanges[resource] ?? [], playedRanges[resource] ?? []))
            prefetchRanges[resource] = nil; playedRanges[resource] = nil; resourceOwners[resource] = nil
        }
        prefetched = prefetched.filter { retained.contains($0.key) }
        exhaustedPrefixes = exhaustedPrefixes.filter { retained.contains($0.key) }
        // Playlists follow their item, not its routes: an upcoming item has no child
        // routes until AVPlayer reads its master, and prefetched playlists must survive until then.
        playlists.retain(owners: retained, now: ProcessInfo.processInfo.systemUptime, ttl: configuration.playlistTTL)
    }
    func retainPlaylist(_ items: [HMMediaItem]) async {
        let owners = Set(items.compactMap(\.url).map { key($0) })
        let removed = playlistOwners.subtracting(owners)
        playlistOwners = owners
        // Shared HLS child resources retain all known owners, independent of entry IDs.
        let shared = Dictionary(uniqueKeysWithValues: resourceOwners.compactMap { resource, roots -> (String, String)? in
            roots.intersection(owners).sorted().first.map { (resource, $0) }
        })
        await cache.release(owners: removed, sharedResources: shared)
        cachedBytes = await cache.sizes(); state.setBytes(cachedBytes)
    }
    func markPlayed(_ item: HMMediaItem) {
        guard let url = item.url else { return }
        activePlaybackItem = item
        wakeBudgetWaiters()
        for (token, (waiting, continuation)) in activationWaiters where waiting.hasSameMedia(as: item, ignoring: configuration.volatileSigningQueryParameters) {
            activationWaiters[token] = nil; continuation.resume()
        }
        for (key, ranges) in warmDeliveries.removeValue(forKey: identity(item)) ?? [:] { playedRanges[key] = HMRangeCoverage.union((playedRanges[key] ?? []) + ranges) }
        // Repeated playlist IDs share a media path and disk entries.
        let owner = key(url)
        Task { await cache.markPlayed(owner) }
    }
    /// Native playback and explicit prefixes share the origin's capacity.
    /// Hold surviving prefixes and native neighbours with backpressure, preserving their
    /// proxy connection and cache path until the current item displays/recovers.
    /// An admitted item keeps or starts its explicit prefix while playback is urgent.
    /// The new current item's own prefix, if mid-download, finishes that resource and stops.
    func prioritizePlayback(_ item: HMMediaItem, urgent: Bool, admitting admitted: HMMediaItem? = nil) {
        if activePlaybackItem?.hasSameMedia(as: item, ignoring: configuration.volatileSigningQueryParameters) == true { activePlaybackItem = item }
        else {
            // A new inactive preparation visit has its own cap; another entry ID
            // sharing the URL retains its independent budget and all cached bytes.
            if let previous = activePlaybackItem { speculativeReceived[identity(previous)] = 0 }
            activePlaybackItem = nil
        }
        priorityItem = item; playbackUrgent = urgent; admittedItem = urgent ? admitted : nil
        for waiter in resourceWaiters.values where isCurrentRequest(waiter.item) { boostResource(waiter.key) }
        if prefixWork[identity(item)] != nil { winding.insert(identity(item)) }
        for key in Array(prefixWaiters.keys) where key == identity(item) {
            parkedPrefixes.remove(key); prefixWaiters.removeValue(forKey: key)?.1.resume()
        }
        for (id, (owner, waiter)) in priorityWaiters where progressAllowed && (!urgent || isAdmitted(owner) || owner.hasSameMedia(as: item, ignoring: configuration.volatileSigningQueryParameters)) {
            priorityWaiters[id] = nil
            emit(.transfer, item: owner, metrics: ["proxy_priority_resume": 1])
            waiter.resume()
        }
        startQueuedPrefixes()
    }
    func setProgressAllowed(_ allowed: Bool) {
        progressAllowed = allowed
        if let item = priorityItem { prioritizePlayback(item, urgent: playbackUrgent, admitting: admittedItem) }
    }
    private func waitUntilPlayed(_ item: HMMediaItem) async throws {
        guard !isActivePlayback(item) else { return }
        let token = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { activationWaiters[token] = (item, continuation) }
            }
        } onCancel: { Task { await self.cancelActivationWaiter(token) } }
        try Task.checkCancellation()
    }
    private func cancelActivationWaiter(_ token: UUID) { activationWaiters.removeValue(forKey: token)?.1.resume(throwing: CancellationError()) }
    private func waitForPlaybackPriority(_ item: HMMediaItem) async throws {
        try Task.checkCancellation()
        guard !isFinishing else { throw CancellationError() }
        if progressAllowed, !playbackUrgent || isAdmitted(item) || priorityItem?.hasSameMedia(as: item, ignoring: configuration.volatileSigningQueryParameters) == true { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { waiter.resume(throwing: CancellationError()) }
                else {
                    priorityWaiters[id] = (item, waiter)
                    emit(.transfer, item: item, metrics: ["proxy_priority_hold": 1])
                }
            }
        } onCancel: { Task { await self.cancelPriorityWaiter(id) } }
    }
    private func cancelPriorityWaiter(_ id: UUID) {
        priorityWaiters.removeValue(forKey: id)?.1.resume(throwing: CancellationError())
    }
    #if DEBUG
    var heldPlaybackRequestCount: Int { priorityWaiters.count }
    var parkedNativeRequestCount: Int { activationWaiters.count + budgetWaiters.count }
    var activePrefetchTokens: [String: UUID] {
        Dictionary(uniqueKeysWithValues: prefixWork.values.map { ($0.item.id, $0.token) })
    }
    var joinedPlaybackRequestCount: Int { resourceWaiters.count }
    var prefetchDownloadCount: Int { prefetchFetching.values.reduce(0) { $0 + $1 } }
    #endif
    /// A spared in-flight prefix keeps its epoch and plan, so its completion still counts.
    /// A winding prefix is always spared, except when the transport finishes.
    func cancelPrefetch(sparing spared: [HMMediaItem] = []) {
        let kept = Set(spared.map { identity($0) }).union(isFinishing ? [] : winding).filter { prefixWork[$0] != nil }
        if !kept.isEmpty {
            prefixQueue.removeAll()
            for identity in Array(prefixWork.keys) where !kept.contains(identity) { cancelPrefix(identity) }
            return
        }
        workEpoch.cancel()
        prefixQueue.removeAll(); prefixPlan = nil; prefixBudget = ""
        for identity in Array(prefixWork.keys) { cancelPrefix(identity) }
    }
    func cancelPrefetch(sparing spared: HMMediaItem?) { cancelPrefetch(sparing: spared.map { [$0] } ?? []) }
    private func isAdmitted(_ item: HMMediaItem) -> Bool {
        progressAllowed && (!playbackUrgent || admittedItem?.hasSameMedia(as: item, ignoring: configuration.volatileSigningQueryParameters) == true)
    }
    private func cancelPrefix(_ identity: HMMediaItem.MediaIdentity) {
        guard let work = prefixWork.removeValue(forKey: identity) else { return }
        winding.remove(identity)
        work.task.cancel(); retiringPrefetch[work.token] = work.task
        emit(.transfer, item: work.item, properties: ["prefetch_work": "cancelled"])
        Task { await work.task.value; removeRetiring(work.token) }
    }
    private func removeRetiring(_ id: UUID) {
        retiringPrefetch[id] = nil
        startQueuedPrefixes()
        trimWindow(retainedItems)
    }
    func prefetch(_ requested: [HMMediaItem], keeping: [HMMediaItem], plan: HMPrefetchPlan) async {
        // Urgent playback admits at most the admitted item; otherwise nothing changes.
        let items = requested
        guard port != 0, !disabled, configuration.strategy.usesDataCache,
              !plan.paused, plan.concurrency > 0 else { return }
        let budget = "\(plan.bytesPerItem)|\(plan.secondsPerItem ?? -1)|\(plan.startingBitRate)"
        // Budget/config changes may restart work; playlist edits retain every overlapping download.
        if !prefixBudget.isEmpty, prefixBudget != budget { cancelPrefetch() }
        prefixBudget = budget; prefixPlan = plan
        let keep = Set(keeping.map(identity))
        for identity in Array(prefixWork.keys) where !keep.contains(identity) { cancelPrefix(identity) }
        let requestedKeys = items.map(identity)
        prefixOrder = requestedKeys + prefixWork.keys.filter { keep.contains($0) && !requestedKeys.contains($0) }
        prefixQueue = items.filter { prefixWork[identity($0)] == nil }
        await cache.configure(capacity: configuration.cacheCapacityBytes, pinned: Set(keeping.compactMap(\.url).map { key($0) }))
        cachedBytes = await cache.sizes(); state.setBytes(cachedBytes)
        prefetched = prefetched.filter { cachedBytes[$0.key] != nil || playlists.contains(owner: $0.key) || exhaustedPrefixes[$0.key] == $0.value }
        startQueuedPrefixes()
    }
    private func startQueuedPrefixes() {
        guard let plan = prefixPlan, !isFinishing else { return }
        // A held task retains its token and byte progress but owns no transfer slot.
        // Finish the bounded chunk already in flight before yielding to a new next item.
        let limit = min(1, plan.concurrency)
        while prefixWork.keys.filter({ !winding.contains($0) && !parkedPrefixes.contains($0) }).count + retiringPrefetch.count < limit {
            let candidate = prefixOrder.first { key in
                if let work = prefixWork[key] { return parkedPrefixes.contains(key) && isAdmitted(work.item) }
                return prefixQueue.contains { identity($0) == key && isAdmitted($0) }
            }
            guard let candidate else { break }
            if parkedPrefixes.remove(candidate) != nil {
                prefixWaiters.removeValue(forKey: candidate)?.1.resume()
                publishPrefixes(); continue
            }
            guard let index = prefixQueue.firstIndex(where: { identity($0) == candidate }) else { break }
            let item = prefixQueue[index], token = UUID(), epoch = generation
            let task = Task(priority: .utility) { [weak self] in
                guard let self else { return }
                await prefetchEntry(item, plan: plan, epoch: epoch)
                await self.completePrefix(identity(item), token: token)
            }
            prefixWork[identity(item)] = PrefixWork(token: token, item: item, task: task)
            prefixQueue.remove(at: index)
            emit(.transfer, item: item, properties: ["prefetch_work": "started", "work_token": token.uuidString])
        }
    }
    private func publishPrefixes() {
        state.setPrefixing(prefixWork.values.filter { !parkedPrefixes.contains(identity($0.item)) }.map { $0.item },
            queued: prefixQueue + prefixWork.values.filter { parkedPrefixes.contains(identity($0.item)) }.map { $0.item })
    }
    private func waitForPrefetchPriority(_ item: HMMediaItem) async throws {
        try Task.checkCancellation()
        let key = identity(item)
        guard !winding.contains(key) else { return }
        let first = prefixOrder.first { candidate in
            if let work = prefixWork[candidate] { return !winding.contains(candidate) && isAdmitted(work.item) }
            return prefixQueue.contains { identity($0) == candidate && isAdmitted($0) }
        }
        if isAdmitted(item), first == nil || first == key { return }
        let token = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                parkedPrefixes.insert(key); prefixWaiters[key] = (token, continuation)
                emit(.transfer, item: item, properties: ["prefetch_work": "held", "work_token": prefixWork[key]?.token.uuidString ?? "unknown"])
                publishPrefixes(); startQueuedPrefixes()
            }
        } onCancel: { Task { await self.cancelPrefixWaiter(key, token: token) } }
        try Task.checkCancellation()
    }
    private func cancelPrefixWaiter(_ key: HMMediaItem.MediaIdentity, token: UUID) {
        guard prefixWaiters[key]?.0 == token else { return }
        parkedPrefixes.remove(key); prefixWaiters.removeValue(forKey: key)?.1.resume(throwing: CancellationError())
        publishPrefixes(); startQueuedPrefixes()
    }
    private func completePrefix(_ identity: HMMediaItem.MediaIdentity, token: UUID) {
        guard let work = prefixWork[identity], work.token == token else { return }
        prefixWork[identity] = nil; winding.remove(identity); parkedPrefixes.remove(identity)
        emit(.transfer, item: work.item, properties: ["prefetch_work": "completed", "work_token": token.uuidString])
        startQueuedPrefixes(); trimWindow(retainedItems)
    }
    private func prefetchEntry(_ item: HMMediaItem, plan: HMPrefetchPlan, epoch: Int) async {
        guard let url = item.url, !url.isFileURL, !Task.isCancelled, epoch == generation else { return }
        let identity = key(url)
        let budgetID = "\(plan.bytesPerItem)|\(plan.secondsPerItem ?? -1)|\(plan.startingBitRate)"
        guard prefetched[identity] != budgetID else { return }
        do {
            try await prefetchWithRetry(item, budget: plan.bytesPerItem, seconds: plan.secondsPerItem,
                bitRate: plan.startingBitRate, epoch: epoch)
            if !Task.isCancelled, epoch == generation { prefetched[identity] = budgetID }
        } catch {
            if !Task.isCancelled, epoch == generation, !(error is CancellationError) {
                exhaustedPrefixes[identity] = budgetID
                prefetched[identity] = budgetID // Exhausted work stays exhausted through ranked refreshes.
                emit(.prefetchError, item: item, properties: ["message": error.localizedDescription, "epoch": String(epoch), "attempt_limit": "3"])
            }
        }
        cachedBytes[identity] = await cache.bytes(for: identity); state.setBytes(cachedBytes)
    }
    private func prefetchWithRetry(_ item: HMMediaItem, budget: Int, seconds: Double?, bitRate: Double, epoch: Int) async throws {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            guard epoch == generation else { throw CancellationError() }
            do { try await prefetchItem(item, budget: budget, seconds: seconds, bitRate: bitRate); return }
            catch {
                guard attempt < 2, !(error is CancellationError), !(error is BudgetError) else { throw error }
                try await Task.sleep(for: .seconds(attempt == 0 ? 0.5 : 2))
            }
        }
    }
    private func prefetchItem(_ item: HMMediaItem, budget: Int, seconds: Double?, bitRate: Double) async throws {
        guard let mediaURL = item.url else { return }
        guard budget > 0, seconds == nil || seconds! > 0 else { return }
        var remaining = budget
        if item.format != .hls {
            var cursor = 0
            while cursor < remaining {
                let t = try await fetch(mediaURL, item: item, start: cursor, count: min(512 * 1024, remaining - cursor), prefetch: true)
                cursor += t.data.count
                remaining = min(remaining, t.total)
                if let seconds, let duration = item.durationHint, duration > 0 {
                    remaining = min(remaining, max(0, Int(Double(t.total) * min(1, max(0, seconds) / duration))))
                }
                guard !t.data.isEmpty else { break }
            }
            return
        }
        do {
        let outcome = try await HMHLSPrefetcher(budget: remaining, seconds: seconds, cap: bitRate).run(mediaURL) { [weak self] url, start, count in
            guard let self else { throw CancellationError() }
            let t = try await self.fetch(url, item: item, start: start, count: count, prefetch: true)
            return HMHLSPrefetcher.Response(data: t.data, total: t.total, base: t.base, cost: t.cost)
        }
        emit(.transfer, item: item, metrics: ["prefetch_duration_s": outcome.seconds,
            "prefetch_target_met": outcome.targetMet ? 1 : 0, "prefix_payload_bytes": Double(outcome.bytes)],
            properties: ["prefix_outcome": outcome.reason])
        } catch let error as BudgetError {
            emit(.transfer, item: item, metrics: ["prefetch_target_met": 0],
                properties: ["prefix_outcome": error == .exhausted ? "byte-cap-consumed-by-shared-native-reads" : "origin-range-unsupported"])
        }
    }
    /// HEAD is optional origin metadata. GET probes are bounded, budgeted and cached
    /// through the ordinary transfer path, after releasing the metadata lock.
    private func metadata(_ url: URL, item: HMMediaItem, prefetch: Bool) async throws -> Transfer {
        let key = key(url)
        if prefetch { try await waitForPrefetchPriority(item) }
        try await acquireResource(key, item: item, prefetch: prefetch)
        let known: Transfer?
        do {
            defer { unlockResource(key) }
            if let hit = playlists.value(for: key, now: ProcessInfo.processInfo.systemUptime, ttl: configuration.playlistTTL) {
                if let root = item.url { playlists.associate(key, owner: self.key(root)) }
                return Transfer(data: hit.data, total: hit.total, mime: hit.mime, base: hit.base, start: 0)
            }
            if let total = await cache.total(for: key) {
                return Transfer(data: Data(), total: total, mime: await cache.mime(for: key) ?? HMCacheKey.mime(url), base: url, start: 0)
            }
            if prefetch { metadataPrefixResources.insert(key) }
            defer { if prefetch { metadataPrefixResources.remove(key) } }
            var request = URLRequest(url: url); request.httpMethod = "HEAD"
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            do {
                let result = try await HMHTTPFetcher(limit: 0).load(request)
                let total = Int(result.response.expectedContentLength)
                known = total > 0 ? Transfer(data: Data(), total: total, mime: result.response.mimeType ?? HMCacheKey.mime(url), base: result.response.url ?? url, start: 0) : nil
            } catch {
                let underlying = (error as? HMHTTPFetcher.Failure)?.underlying ?? error
                guard case HMHTTPFetcher.HTTPError.status(let status) = underlying,
                      [403, 405, 501].contains(status) else { throw error }
                known = nil
            }
        }
        if let known { return known }
        try Task.checkCancellation()
        let playlist = url.pathExtension.lowercased() == "m3u8" || (url == item.url && item.format == .hls)
        // A manifest probe can be the whole bounded manifest. Media probes only
        // learn total size; no segment round is downloaded before admission.
        return try await fetch(url, item: item, start: 0, count: playlist ? HMHLSPrefetcher.playlistRead : 1, prefetch: prefetch)
    }
    private func fetch(_ url: URL, item: HMMediaItem, start: Int, count: Int, prefetch: Bool) async throws -> Transfer {
        try Task.checkCancellation()
        guard count >= 0, ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw URLError(.unsupportedURL) }
        if count == 0 { return try await metadata(url, item: item, prefetch: prefetch) }
        let key = key(url)
        if prefetch { try await waitForPrefetchPriority(item) }
        try await acquireResource(key, item: item, prefetch: prefetch)
        var locked = true
        defer { if locked { unlockResource(key) } }
        inFlightResources[key, default: 0] += 1
        defer { releaseResource(key) }
        let playlist = url.pathExtension.lowercased() == "m3u8" || (url == item.url && item.format == .hls)
        if playlist, let hit = playlists.value(for: key, now: ProcessInfo.processInfo.systemUptime, ttl: configuration.playlistTTL) {
            if let root = item.url { playlists.associate(key, owner: self.key(root)) }
            if !prefetch {
                recordDelivery(key: key, item: item, start: start, count: hit.data.count)
                emit(.transfer, item: item, metrics: ["cache_bytes": Double(hit.data.count), "network_bytes": 0])
            }
            return Transfer(data: hit.data, total: hit.total, mime: hit.mime, base: hit.base, start: hit.start)
        }
        guard let mediaURL = item.url else { throw URLError(.unsupportedURL) }
        let owner = self.key(mediaURL)
        if !playlist, configuration.strategy.usesDataCache, let total = await cache.total(for: key) {
            let end = min(total - 1, start + count - 1)
            if end >= start, let hit = await cache.available(key: key, start: start, count: count) {
                await cache.associate(key: key, owner: owner, played: isActivePlayback(item))
                resourceOwners[key, default: []].insert(owner)
                if !prefetch {
                    recordDelivery(key: key, item: item, start: start, count: hit.data.count)
                    emit(.transfer, item: item, metrics: ["cache_bytes": Double(hit.data.count), "network_bytes": 0])
                }
                return Transfer(data: hit.data, total: hit.total, mime: hit.mime, base: hit.base, start: start)
            }
        }
        if prefetch {
            // A winding prefix starts no new download: playback reads the rest itself.
            if winding.contains(identity(item)) { throw CancellationError() }
            prefetchFetching[key, default: 0] += 1
        }
        defer { if prefetch { endPrefetchFetch(key) } }
        unlockResource(key); locked = false
        let allocation = try await reserve(item, count: count, prefetch: prefetch)
        defer { release(allocation) }
        try await acquireResource(key, item: item, prefetch: prefetch); locked = true
        // A native owner may have completed while reservation/lock acquisition waited.
        if !playlist, count > 0, let hit = await cache.available(key: key, start: start, count: count) {
            await cache.associate(key: key, owner: owner, played: isActivePlayback(item))
            resourceOwners[key, default: []].insert(owner)
            if !prefetch {
                recordDelivery(key: key, item: item, start: start, count: hit.data.count)
                emit(.transfer, item: item, metrics: ["cache_bytes": Double(hit.data.count), "network_bytes": 0])
            }
            return Transfer(data: hit.data, total: hit.total, mime: hit.mime, base: hit.base, start: start)
        }
        if playlist, let hit = playlists.value(for: key, now: ProcessInfo.processInfo.systemUptime, ttl: configuration.playlistTTL) {
            playlists.associate(key, owner: owner)
            if !prefetch {
                recordDelivery(key: key, item: item, start: start, count: hit.data.count)
                emit(.transfer, item: item, metrics: ["cache_bytes": Double(hit.data.count), "network_bytes": 0])
            }
            return Transfer(data: hit.data, total: hit.total, mime: hit.mime, base: hit.base, start: hit.start)
        }

        let count = allocation.count
        var request = URLRequest(url: url)
        request.setValue("bytes=\(start)-\(start + count - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let result: HMHTTPFetcher.Result
        do { result = try await HMHTTPFetcher(limit: max(1, count), priority: prefetch ? URLSessionTask.lowPriority : URLSessionTask.highPriority,
            measurement: measurementHandler(item, speculative: prefetch), headers: { response in
                if prefetch, count > 0 {
                    let range = response.value(forHTTPHeaderField: "Content-Range")
                    let end = range?.dropFirst(6).split(separator: "/").first?.split(separator: "-").last.flatMap { Int($0) }
                    let total = range?.split(separator: "/").last.flatMap { Int($0) }
                    let ranged = response.statusCode == 206 && range?.hasPrefix("bytes \(start)-") == true &&
                        end.map { end in total.map { end >= start && end - start < count && end < $0 } == true &&
                            (response.expectedContentLength < 0 || response.expectedContentLength == end - start + 1) } == true
                    let complete = response.statusCode == 200 && start == 0 && response.expectedContentLength >= 0 && response.expectedContentLength <= count
                    guard ranged || complete else { throw BudgetError.rangeUnsupported }
                }
            }).load(request) }
        catch {
            if let failure = error as? HMHTTPFetcher.Failure {
                account(failure.received, url: url, item: item, prefetch: prefetch, speculative: prefetch || allocation.owner != nil)
                if let budgetError = failure.underlying as? BudgetError { throw budgetError }
            }
            throw error
        }
        account(result.received, url: url, item: item, prefetch: prefetch, speculative: prefetch || allocation.owner != nil)
        let http = result.response
        let contentRange = http.value(forHTTPHeaderField: "Content-Range")
        let total = contentRange?.split(separator: "/").last.flatMap { Int($0) } ?? Int(http.expectedContentLength)
        guard total > 0, start < total, http.statusCode != 200 || start == 0 || count == 0 else { throw URLError(.badServerResponse) }
        if http.statusCode == 206 {
            guard contentRange?.hasPrefix("bytes \(start)-") == true else { throw URLError(.badServerResponse) }
        }
        let mime = http.mimeType ?? HMCacheKey.mime(url)
        let data = result.data
        if prefetch || allocation.owner != nil, !data.isEmpty { prefetchRanges[key] = HMRangeCoverage.union((prefetchRanges[key] ?? []) + [HMByteRange(start: start, end: start + data.count - 1)]) }
        if !prefetch, !data.isEmpty { recordDelivery(key: key, item: item, start: start, count: data.count) }
        try Task.checkCancellation()
        if !playlist, configuration.strategy.usesDataCache {
            await cache.put(key: key, start: start, data: data, total: total, mime: mime, base: http.url ?? url, owner: owner,
                            prefetched: prefetch, played: isActivePlayback(item))
            cachedBytes[owner] = await cache.bytes(for: owner); state.setBytes(cachedBytes)
        }
        let transfer = Transfer(data: data, total: total, mime: mime, base: http.url ?? url, start: start, cost: result.received)
        if playlist, data.count == total {
            playlists.store(transfer, for: key, owner: owner, immutable: HMHLS.text(data).map(HMHLS.isImmutable) ?? false,
                            now: ProcessInfo.processInfo.systemUptime)
        }
        return transfer
    }
    private func reserve(_ item: HMMediaItem, count: Int, prefetch: Bool) async throws -> Allocation {
        guard count > 0, !isActivePlayback(item), item.url != nil else { return Allocation(count: count, owner: nil) }
        let owner = identity(item), cap = min(HMPrefetchPolicy.maximumBytesPerItem, max(0, configuration.prefetch.bytesPerItem))
        while !isActivePlayback(item) {
            try Task.checkCancellation()
            let available = max(0, cap - speculativeReceived[owner, default: 0] - reservedSpeculative[owner, default: 0])
            if available > 0 {
                let granted = min(count, available); reservedSpeculative[owner, default: 0] += granted
                return Allocation(count: granted, owner: owner)
            }
            if prefetch, speculativeReceived[owner, default: 0] >= cap { throw BudgetError.exhausted }
            let token = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { budgetWaiters[token] = (item, continuation) }
                }
            } onCancel: { Task { await self.cancelBudgetWaiter(token) } }
        }
        return Allocation(count: count, owner: nil)
    }
    private func release(_ allocation: Allocation) {
        if let owner = allocation.owner { reservedSpeculative[owner] = max(0, reservedSpeculative[owner, default: 0] - allocation.count) }
        wakeBudgetWaiters()
    }
    private func wakeBudgetWaiters() {
        for (token, (item, continuation)) in budgetWaiters {
            guard item.url != nil else { continue }
            let owner = identity(item), cap = min(HMPrefetchPolicy.maximumBytesPerItem, max(0, configuration.prefetch.bytesPerItem))
            if isActivePlayback(item) || speculativeReceived[owner, default: 0] + reservedSpeculative[owner, default: 0] < cap {
                budgetWaiters[token] = nil; continuation.resume()
            }
        }
    }
    private func cancelBudgetWaiter(_ token: UUID) { budgetWaiters.removeValue(forKey: token)?.1.resume(throwing: CancellationError()) }
    private func measurementHandler(_ item: HMMediaItem, speculative: Bool) -> @Sendable (Int, Double, Double?) -> Void {
        { [weak self] bytes, seconds, ttfb in
            Task { await self?.recordMeasurement(item, bytes: bytes, seconds: seconds, ttfb: ttfb, speculative: speculative) }
        }
    }
    private func recordMeasurement(_ item: HMMediaItem, bytes: Int, seconds: Double, ttfb: Double?, speculative: Bool) {
        var metrics = ["sample_bytes": Double(bytes), "receive_s": seconds]
        if let ttfb { metrics["ttfb_s"] = ttfb }
        emit(.transferSample, item: item, metrics: metrics, properties: ["source": speculative ? "prefetch" : "playback"])
    }
    /// Both directions join one resource download and then re-read the disk/memory
    /// cache. Cancellation releases the waiter, never another caller's transfer.
    private func isActivePlayback(_ item: HMMediaItem) -> Bool { activePlaybackItem?.hasSameMedia(as: item, ignoring: configuration.volatileSigningQueryParameters) == true }
    private func isCurrentRequest(_ item: HMMediaItem) -> Bool { priorityItem?.hasSameMedia(as: item, ignoring: configuration.volatileSigningQueryParameters) == true }
    /// Current or an admitted prefix may preempt a warm native socket holding this exact resource.
    /// Its bounded received bytes are flushed by stream cancellation and reused;
    /// explicit prefix owners finish one bounded chunk and remain coalesced.
    private func boostResource(_ key: String, forPrefix: Bool = false) {
        guard let holder = resourceHolders[key] else { return }
        // Native activation does not need an unresponsive speculative HEAD.
        // Prefix waiters never cancel another explicit prefix owner.
        if !forPrefix, metadataPrefixResources.contains(key) {
            cancelPrefix(identity(holder)); return
        }
        guard !isCurrentRequest(holder), let connection = nativeResourceConnections[key] else { return }
        emit(.transfer, item: holder, metrics: ["proxy_priority_preemption": 1])
        close(connection, reason: forPrefix ? "prefix-shared-resource-preemption" : "current-shared-resource-preemption")
    }
    private func acquireResource(_ key: String, item: HMMediaItem, connectionID: UUID? = nil, prefetch: Bool = false) async throws {
        while downloadingResources.contains(key) {
            if isCurrentRequest(item) || prefetch { boostResource(key, forPrefix: prefetch && !isCurrentRequest(item)) }
            let token = UUID()
            emit(.transfer, item: item, metrics: ["prefetch_join": 1], properties: ["resource": HMCacheKey.hash(key)])
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { resourceWaiters[token] = (key, item, continuation) }
                }
            } onCancel: { Task { await self.cancelResourceWaiter(token) } }
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        downloadingResources.insert(key); resourceHolders[key] = item; nativeResourceConnections[key] = connectionID
    }
    private func cancelResourceWaiter(_ token: UUID) {
        guard let waiter = resourceWaiters.removeValue(forKey: token) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }
    private func unlockResource(_ key: String) {
        downloadingResources.remove(key)
        resourceHolders[key] = nil; nativeResourceConnections[key] = nil
        let waiters = resourceWaiters.filter { $0.value.key == key }
        for (token, waiter) in waiters {
            resourceWaiters[token] = nil; waiter.continuation.resume()
        }
    }
    private func endPrefetchFetch(_ key: String) {
        if let count = prefetchFetching[key], count > 1 { prefetchFetching[key] = count - 1 }
        else { prefetchFetching[key] = nil }
    }
    private func releaseResource(_ key: String) {
        if let count = inFlightResources[key], count > 1 { inFlightResources[key] = count - 1 }
        else { inFlightResources[key] = nil }
    }
    private func recordDelivery(key: String, item: HMMediaItem, start: Int, count: Int) {
        let range = HMByteRange(start: start, end: start + count - 1)
        if let url = item.url { resourceOwners[key, default: []].insert(self.key(url)) }
        if isActivePlayback(item) { playedRanges[key] = HMRangeCoverage.union((playedRanges[key] ?? []) + [range]) }
        else { warmDeliveries[identity(item), default: [:]][key] = HMRangeCoverage.union((warmDeliveries[identity(item)]?[key] ?? []) + [range]) }
    }
    private func account(_ bytes: Int, url: URL, item: HMMediaItem, prefetch: Bool, speculative: Bool? = nil) {
        if let mediaURL = item.url { resourceOwners[key(url), default: []].insert(key(mediaURL)) }
        let speculative = speculative ?? (prefetch || !isActivePlayback(item))
        if speculative {
            prefetchedNetwork[key(url), default: 0] += bytes
            speculativeReceived[identity(item), default: 0] += bytes
        }
        emit(.transfer, item: item, metrics: ["network_bytes": Double(bytes), "cache_bytes": 0, "prefetch_bytes": speculative ? Double(bytes) : 0], properties: ["resource": HMCacheKey.hash(key(url))])
    }
    private func accept(_ connection: NWConnection) {
        guard !isFinishing else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { await self?.close(id, reason: "connection-failed") } }
            if case .cancelled = state { Task { await self?.close(id, reason: "connection-cancelled") } }
        }
        connection.start(queue: queue); receive(connection, id: id, accumulated: Data())
    }
    private func receive(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            Task {
                guard let self else { connection.cancel(); return }
                var buffer = accumulated; buffer.append(data ?? Data())
                if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let header = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                    await self.respond(header, connection: connection, id: id)
                } else if buffer.count > 16 * 1024 || complete || error != nil { await self.close(id) }
                else { await self.receive(connection, id: id, accumulated: buffer) }
            }
        }
    }
    private func respond(_ header: String, connection: NWConnection, id: UUID) {
        responseTasks[id] = Task { [weak self] in await self?.serve(header, connection: connection, id: id) }
    }
    private func serve(_ header: String, connection: NWConnection, id: UUID) async {
        let lines = header.components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ")
        guard request.count >= 2, request[0] == "GET" || request[0] == "HEAD" else { send(connection, id: id, code: 405, headers: [:], body: Data()); return }
        let token = request[1].split(separator: "/").first.map(String.init) ?? ""
        if token == "health" { send(connection, id: id, code: 200, headers: [:], body: Data()); return }
        guard let route = state.route(token) else { send(connection, id: id, code: 404, headers: [:], body: Data()); return }
        responseItems[id] = route.item
        let rangeHeader = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }.map { $0.dropFirst(6).trimmingCharacters(in: .whitespaces) }
        do {
            try await waitForPlaybackPriority(route.item)
            if route.url.pathExtension.lowercased() == "m3u8" || (route.url == route.item.url && route.item.format == .hls) {
                let t = try await fetch(route.url, item: route.item, start: 0, count: 512 * 1024, prefetch: false)
                try await waitForPlaybackPriority(route.item)
                guard t.data.count == t.total, let text = String(data: t.data, encoding: .utf8) else { throw URLError(.badServerResponse) }
                let body = Data(HMPlaylist.rewrite(text, base: t.base) { proxyURL($0, item: route.item) }.utf8)
                send(connection, id: id, code: 200, headers: ["Content-Type": "application/vnd.apple.mpegurl", "Content-Length": String(body.count)], body: request[0] == "HEAD" ? Data() : body)
                return
            }
            let key = key(route.url)
            let total = configuration.strategy.usesDataCache ? await cache.total(for: key) : nil
            // Preserve the player's request on uncached resources, including
            // no-Range requests. There is no preliminary size probe.
            if total == nil {
                try await acquireResource(key, item: route.item, connectionID: id)
                do {
                    // Another reader may have filled the head while we waited.
                    if await cache.total(for: key) != nil { unlockResource(key); await serve(header, connection: connection, id: id); return }
                    try await stream(route, range: rangeHeader, headOnly: request[0] == "HEAD", connection: connection, limit: 512 * 1024)
                    unlockResource(key)
                } catch { unlockResource(key); throw error }
                close(id); return
            }
            guard let total, let range = HMByteRange.parse(rangeHeader, total: total, limit: Int.max) else {
                send(connection, id: id, code: 416, headers: ["Content-Range": "bytes */\(total ?? 0)"], body: Data()); return
            }
            let mime = await cache.mime(for: key) ?? HMCacheKey.mime(route.url)
            var h = ["Content-Type": mime, "Accept-Ranges": "bytes", "Content-Range": "bytes \(range.start)-\(range.end)/\(total)", "Content-Length": String(range.count), "Connection": "close", "Cache-Control": "no-store"]
            if rangeHeader == nil { h["Content-Range"] = nil }
            let head = "HTTP/1.1 \(rangeHeader == nil ? "200 OK" : "206 Partial Content")\r\n" + h.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n"
            try await waitForPlaybackPriority(route.item)
            try await sendBlock(connection, data: Data(head.utf8))
            if request[0] != "HEAD" {
                var cursor = range.start
                while cursor <= range.end {
                    try await waitForPlaybackPriority(route.item)
                    if let hit = await cache.available(key: key, start: cursor, count: range.end - cursor + 1) {
                        if let root = route.item.url { await cache.associate(key: key, owner: self.key(root), played: isActivePlayback(route.item)) }
                        recordDelivery(key: key, item: route.item, start: cursor, count: hit.data.count)
                        emit(.transfer, item: route.item, metrics: ["cache_bytes": Double(hit.data.count), "network_bytes": 0])
                        try await sendBlock(connection, data: hit.data)
                        cursor += hit.data.count
                    } else {
                        // Knowing the total (often from AVPlayer's two-byte probe)
                        // must not turn a miss into a fully buffered 512 KiB fetch.
                        // Stream the missing suffix immediately, independently of
                        // any cancelled/overlapping speculative range.
                        try await acquireResource(key, item: route.item, connectionID: id)
                        if await cache.available(key: key, start: cursor, count: range.end - cursor + 1) != nil {
                            unlockResource(key); continue
                        }
                        let delivered: Int
                        do {
                            delivered = try await stream(route, range: "bytes=\(cursor)-\(range.end)", headOnly: false,
                                connection: connection, sendHeaders: false, limit: min(512 * 1024, range.end - cursor + 1))
                            unlockResource(key)
                        } catch { unlockResource(key); throw error }
                        guard delivered > 0 else { throw URLError(.badServerResponse) }
                        cursor += delivered
                    }
                }
            }
            close(id)
        } catch {
            if !Task.isCancelled {
                // A client closing a completed AVFoundation probe is normal.
                let underlying = (error as? HMHTTPFetcher.Failure)?.underlying ?? error
                if !(underlying is NativeTransportFallback), !(underlying is NWError), (underlying as NSError).code != NSURLErrorCancelled { emit(.transportError, item: route.item, properties: ["message": error.localizedDescription]) }
                close(id, reason: "response-error")
            }
        }
    }
    @discardableResult
    private func stream(_ route: Route, range: String?, headOnly: Bool, connection: NWConnection, sendHeaders: Bool = true, limit: Int = Int.max) async throws -> Int {
        let streamID = UUID()
        let resource = key(route.url); inFlightResources[resource, default: 0] += 1
        defer { releaseResource(resource) }
        try await waitForPlaybackPriority(route.item)
        let allocation = try await reserve(route.item, count: headOnly ? 0 : limit, prefetch: false)
        defer { release(allocation) }
        let limit = allocation.count
        var request = URLRequest(url: route.url)
        request.httpMethod = headOnly ? "HEAD" : "GET"
        var upstreamRange = range
        if !headOnly {
            let pair = range?.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            if let pair, pair.count == 2, pair[0].isEmpty, let suffix = Int(pair[1]) {
                upstreamRange = "bytes=-\(min(suffix, limit))"
            } else {
                let start = pair?.first.flatMap { Int($0) } ?? 0
                let end = pair?.last.flatMap { Int($0) } ?? Int.max
                upstreamRange = "bytes=\(start)-\(min(end, start + min(limit, Int.max - start) - 1))"
            }
        }
        request.setValue(upstreamRange, forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        try await waitForPlaybackPriority(route.item)
        let fetcher = HMHTTPFetcher(limit: limit, priority: isActivePlayback(route.item) ? URLSessionTask.highPriority : URLSessionTask.defaultPriority,
            measurement: measurementHandler(route.item, speculative: !isActivePlayback(route.item)), headers: { [weak self] response in
            guard let self else { throw CancellationError() }
            try await self.waitForPlaybackPriority(route.item)
            if allocation.owner != nil, response.statusCode == 200, response.expectedContentLength > limit {
                // A range-less origin can still play. Hold its unbounded body until
                // activation, with the fetcher's header watchdog suspended.
                try await self.waitUntilPlayed(route.item)
            }
            let requestedStart = range?.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false).first.flatMap { Int($0) } ?? 0
            if !headOnly, response.statusCode == 200,
               requestedStart > 0 || (sendHeaders && response.expectedContentLength > limit) {
                // A range-less origin cannot satisfy the proxy's bounded suffix contract.
                // Keep its body suspended while inactive, then use AVPlayer's direct
                // origin transport on the same node/activation instead of retrying
                // truncated 200 responses indefinitely.
                try await self.waitUntilPlayed(route.item)
                await self.emit(.transportError, item: route.item, properties: [
                    "native_direct_fallback": "origin-range-unsupported",
                    "message": "Origin ignored bounded Range; activated playback uses direct transport"])
                throw NativeTransportFallback.rangeUnsupported
            }
            await self.beginStream(streamID, response: response, speculative: allocation.owner != nil, item: route.item)
            if !sendHeaders {
                let start = range?.dropFirst(6).split(separator: "-").first.flatMap { Int($0) } ?? 0
                guard (response.statusCode == 206 && response.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes \(start)-") == true) ||
                        (response.statusCode == 200 && start == 0) else { throw URLError(.badServerResponse) }
                return
            }
            var headers: [String: String] = [:]
            for name in ["Content-Length", "Content-Range", "Accept-Ranges", "Content-Type"] {
                headers[name] = response.value(forHTTPHeaderField: name)
            }
            headers["Content-Type"] = headers["Content-Type"] ?? HMCacheKey.mime(route.url)
            headers["Connection"] = "close"; headers["Cache-Control"] = "no-store"
            let head = "HTTP/1.1 \(response.statusCode) OK\r\n" + headers.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n"
            try await self.sendBlock(connection, data: Data(head.utf8))
        }, bytes: { [weak self] bytes in
            guard let self else { throw CancellationError() }
            try await self.waitForPlaybackPriority(route.item)
            try await self.sendBlock(connection, data: bytes)
            await self.cacheStream(streamID, bytes: bytes, route: route)
        })
        do {
            let result = try await fetcher.load(request)
            let wasSpeculative = streams[streamID]?.speculative ?? (allocation.owner != nil)
            account(result.received, url: route.url, item: route.item, prefetch: false, speculative: wasSpeculative)
            await cacheStream(streamID, bytes: Data(), route: route, finishing: true)
            return result.delivered
        } catch {
            if let failure = error as? HMHTTPFetcher.Failure { account(failure.received, url: route.url, item: route.item, prefetch: false, speculative: streams[streamID]?.speculative ?? (allocation.owner != nil)) }
            await cacheStream(streamID, bytes: Data(), route: route, finishing: true); throw error
        }
    }
    private func beginStream(_ id: UUID, response: HTTPURLResponse, speculative: Bool, item: HMMediaItem) {
        guard response.statusCode == 200 || response.statusCode == 206 else { return }
        let range = response.value(forHTTPHeaderField: "Content-Range")
        let total = range?.split(separator: "/").last.flatMap { Int($0) } ?? Int(response.expectedContentLength)
        let cursor = range?.dropFirst(6).split(separator: "-").first.flatMap { Int($0) } ?? 0
        streams[id] = StreamState(cursor: cursor, total: total, mime: response.mimeType ?? HMCacheKey.mime(response.url!), base: response.url!, speculative: speculative && !isActivePlayback(item))
    }
    private func cacheStream(_ id: UUID, bytes: Data, route: Route, finishing: Bool = false) async {
        guard var stream = streams[id], let mediaURL = route.item.url else { return }
        if !bytes.isEmpty { recordDelivery(key: key(route.url), item: route.item, start: stream.cursor + stream.buffer.count, count: bytes.count) }
        if stream.speculative, !bytes.isEmpty {
            let resource = key(route.url), start = stream.cursor + stream.buffer.count
            prefetchRanges[resource] = HMRangeCoverage.union((prefetchRanges[resource] ?? []) + [HMByteRange(start: start, end: start + bytes.count - 1)])
        }
        stream.buffer.append(bytes)
        while stream.buffer.count >= 512 * 1024 || (finishing && !stream.buffer.isEmpty) {
            let size = min(512 * 1024, stream.buffer.count)
            let chunk = Data(stream.buffer.prefix(size)); stream.buffer.removeFirst(size)
            if configuration.strategy.usesDataCache, stream.total > 0 {
                let waitingCurrent = resourceWaiters.values.first { waiter in waiter.key == key(route.url) && priorityItem.map { priority in waiter.item.hasSameMedia(as: priority, ignoring: configuration.volatileSigningQueryParameters) } == true }?.item
                let survives = retainedItems.contains { $0.hasSameMedia(as: route.item, ignoring: configuration.volatileSigningQueryParameters) }
                let owner = waitingCurrent?.url.map { key($0) } ?? key(mediaURL)
                await cache.put(key: key(route.url), start: stream.cursor, data: chunk, total: stream.total, mime: stream.mime, base: stream.base,
                                owner: owner, prefetched: false, played: isActivePlayback(route.item),
                                allowCancelled: finishing && (survives || waitingCurrent != nil))
            }
            stream.cursor += size
        }
        streams[id] = finishing ? nil : stream
        if finishing, configuration.strategy.usesDataCache {
            let owner = key(mediaURL); cachedBytes[owner] = await cache.bytes(for: owner); state.setBytes(cachedBytes)
        }
    }
    private func sendBlock(_ connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }
    private func send(_ connection: NWConnection, id: UUID, code: Int, headers: [String: String], body: Data) {
        var h = headers; if h["Content-Length"] == nil { h["Content-Length"] = String(body.count) }
        h["Connection"] = "close"; h["Cache-Control"] = "no-store"
        let prefix = "HTTP/1.1 \(code) \(code == 206 ? "Partial Content" : code == 200 ? "OK" : "Error")\r\n" + h.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n"
        var packet = Data(prefix.utf8); packet.append(body)
        connection.send(content: packet, completion: .contentProcessed { [weak self] _ in Task { await self?.close(id) } })
    }
    private func close(_ id: UUID, reason: String = "completed") {
        if let item = responseItems.removeValue(forKey: id) {
            emit(.transfer, item: item, metrics: ["proxy_close": 1], properties: ["reason": reason])
        }
        responseTasks.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.cancel()
    }
    func finish() async -> Int {
        isFinishing = true
        for id in Array(priorityWaiters.keys) { cancelPriorityWaiter(id) }
        for token in Array(resourceWaiters.keys) { cancelResourceWaiter(token) }
        for token in Array(budgetWaiters.keys) { cancelBudgetWaiter(token) }
        for token in Array(activationWaiters.keys) { cancelActivationWaiter(token) }
        listener?.cancel(); port = 0; state.setPort(0)
        cancelPrefetch()
        let tasks = Array(responseTasks.values) + Array(retiringPrefetch.values)
        retiringPrefetch.removeAll()
        for id in Array(connections.keys) { close(id, reason: "finish") }
        for task in tasks { await task.value }
        listener?.cancel(); port = 0; state.setPort(0)
        // Speculative bytes are useful only where their byte ranges were
        // requested by an activated item's player (warm-only reads do not count).
        await eventDelivery?.value
        return prefetchedNetwork.reduce(retiredWaste) { sum, pair in
            let used = HMRangeCoverage.overlap(prefetchRanges[pair.key] ?? [], playedRanges[pair.key] ?? [])
            return sum + max(0, pair.value - used)
        }
    }

    private func emit(_ kind: HMPlaybackEvent.Kind, item: HMMediaItem, metrics: [String: Double] = [:], properties: [String: String] = [:]) {
        let previous = eventDelivery
        let event = HMPlaybackEvent(kind: kind, itemID: item.id, metrics: metrics, properties: properties)
        if let onEvent { eventDelivery = Task { await previous?.value; await onEvent(event, item) } }
    }
}
#endif
#if canImport(Network) && !os(macOS)
/// The UI facade never parses HTTP, copies payloads or touches cache files.
@MainActor final class HMCacheProxy {
    private let transport: HMCacheTransport
    private var commands: Task<Void, Never>?
    private var retainedWindow: [HMMediaItem]?
    private var retainedPlaylist: [HMMediaItem]?
    private var playbackPriority: HMMediaItem?
    private var playbackUrgent = true
    private var admittedItem: HMMediaItem?
    private var progressAllowed = true
    private func enqueue(_ action: @escaping @Sendable (HMCacheTransport) async -> Void) {
        let previous = commands, transport = transport
        commands = Task { await previous?.value; await action(transport) }
    }
    var configuration: HMPlayerConfiguration { didSet { let value = configuration; enqueue { await $0.updateConfiguration(value) } } }
    var onEvent: ((HMPlaybackEvent, HMMediaItem) -> Void)?
    init(configuration: HMPlayerConfiguration, directory: URL? = nil) throws {
        self.configuration = configuration
        transport = try HMCacheTransport(configuration: configuration, directory: directory)
    }
    func start() async throws {
        await commands?.value
        await transport.setEventHandler { [weak self] event, item in self?.onEvent?(event, item) }
        _ = await transport.start() // Failure deliberately leaves direct playback available.
    }
    func url(for item: HMMediaItem) -> URL? { transport.url(for: item) }
    func cachedByteCount(for item: HMMediaItem) -> Int {
        item.url.map { configuration.strategy.usesDataCache && transport.state.port != 0 ? transport.state.bytes(for: HMCacheKey.canonical($0, ignoring: configuration.volatileSigningQueryParameters)) : 0 } ?? 0
    }
    /// Whether an explicit prefix for the item is issued, queued or in flight. The transport takes
    /// commands some milliseconds after they are issued; a decision in between still sees the prefix.
    func isPrefetching(_ item: HMMediaItem) -> Bool { transport.state.isPrefixing(item) }
    /// Whether the transport has started the item's prefix, so a playback read would join its download.
    func isPrefetchRunning(_ item: HMMediaItem) -> Bool { transport.state.isPrefixRunning(item) }
    func retainWindow(_ items: [HMMediaItem]) {
        guard retainedWindow != items else { return }
        retainedWindow = items
        transport.state.prune(keeping: Set(items))
        enqueue { await $0.retainWindow(items) }
    }
    func retainPlaylist(_ items: [HMMediaItem]) { guard retainedPlaylist != items else { return }; retainedPlaylist = items; enqueue { await $0.retainPlaylist(items) } }
    func setProgressAllowed(_ allowed: Bool) {
        guard progressAllowed != allowed else { return }; progressAllowed = allowed
        enqueue { await $0.setProgressAllowed(allowed) }
    }
    func markPlayed(_ item: HMMediaItem) { enqueue { await $0.markPlayed(item) } }
    func prioritizePlayback(_ item: HMMediaItem, urgent: Bool, admitting: HMMediaItem? = nil) {
        let admitted = urgent ? admitting : nil
        guard playbackPriority != item || playbackUrgent != urgent || admittedItem != admitted else { return }
        playbackPriority = item; playbackUrgent = urgent; admittedItem = admitted
        enqueue { await $0.prioritizePlayback(item, urgent: urgent, admitting: admitted) }
    }
    func cancelPrefetch(sparing: HMMediaItem? = nil) { enqueue { await $0.cancelPrefetch(sparing: sparing) } }
    func cancelPrefetch(sparing: [HMMediaItem]) { enqueue { await $0.cancelPrefetch(sparing: sparing) } }
    func prefetch(_ items: [HMMediaItem], keeping: [HMMediaItem], plan: HMPrefetchPlan) {
        transport.state.issue(items)
        enqueue { await $0.prefetch(items, keeping: keeping, plan: plan); $0.state.settle(items) }
    }
    func finish() async -> Int { await commands?.value; return await transport.finish() }
}

/// Small synchronized route/port snapshot shared with the synchronous player
/// assignment path. Payloads and all network state remain actor isolated.
final class HMProxyState: @unchecked Sendable {
    private let lock = NSLock()
    private var signingParameters: [String]
    init(signingParameters: [String] = []) { self.signingParameters = signingParameters }
    func configure(signingParameters: [String]) {
        lock.lock(); defer { lock.unlock() }
        guard self.signingParameters != signingParameters else { return }
        self.signingParameters = signingParameters
        // Identities change with the parameters; the transport cancels its prefixes on this change too.
        routes.removeAll(); tokens.removeAll(); allowedItems = nil; issued.removeAll()
    }
    private func identity(_ item: HMMediaItem) -> HMMediaItem.MediaIdentity {
        item.mediaIdentity(ignoring: signingParameters)
    }
    private var listeningPort: UInt16 = 0
    private var routes: [String: HMCacheTransport.Route] = [:]
    private var tokens: [String: String] = [:]
    private var cachedBytes: [String: Int] = [:]
    private var prefixing: Set<HMMediaItem.MediaIdentity> = []
    private var runningPrefixes: Set<HMMediaItem.MediaIdentity> = []
    /// Prefetch commands the facade has enqueued and the transport has not taken yet, per item.
    private var issued: [HMMediaItem.MediaIdentity: Int] = [:]
    private var allowedItems: Set<HMMediaItem.MediaIdentity>?
    var port: UInt16 { lock.lock(); defer { lock.unlock() }; return listeningPort }
    func setPort(_ value: UInt16) { lock.lock(); listeningPort = value; lock.unlock() }
    func setBytes(_ value: [String: Int]) { lock.lock(); cachedBytes = value; lock.unlock() }
    func bytes(for key: String) -> Int { lock.lock(); defer { lock.unlock() }; return cachedBytes[key] ?? 0 }
    func setPrefixing(_ running: [HMMediaItem], queued: [HMMediaItem] = []) {
        lock.lock(); defer { lock.unlock() }
        runningPrefixes = Set(running.map { identity($0) })
        prefixing = runningPrefixes.union(queued.map { identity($0) })
    }
    /// Started by the transport, so a playback read can join it; issued or queued work cannot be joined yet.
    func isPrefixRunning(_ item: HMMediaItem) -> Bool { lock.lock(); defer { lock.unlock() }; return runningPrefixes.contains(identity(item)) }
    /// A decision made after the player issues a prefetch, but before the transport takes the
    /// command, must still see it: the player would otherwise cancel the head it just issued.
    func issue(_ items: [HMMediaItem]) {
        lock.lock(); defer { lock.unlock() }
        for item in items { issued[identity(item), default: 0] += 1 }
    }
    /// The transport took the command, whether or not it started work; its own state answers from here.
    func settle(_ items: [HMMediaItem]) {
        lock.lock(); defer { lock.unlock() }
        for item in items {
            let key = identity(item)
            if let count = issued[key], count > 1 { issued[key] = count - 1 } else { issued[key] = nil }
        }
    }
    /// Issued, queued or running.
    func isPrefixing(_ item: HMMediaItem) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let key = identity(item)
        return prefixing.contains(key) || issued[key] != nil
    }
    func route(_ token: String) -> HMCacheTransport.Route? { lock.lock(); defer { lock.unlock() }; return routes[token] }
    func allURLs() -> [URL] { lock.lock(); defer { lock.unlock() }; return routes.values.map(\.url) }
    func url(_ url: URL, item: HMMediaItem) -> URL {
        lock.lock(); defer { lock.unlock() }
        guard listeningPort != 0, allowedItems?.contains(identity(item)) != false else { return url }
        let key = item.id + "|" + HMCacheKey.canonical(url, ignoring: signingParameters)
        let token = tokens[key] ?? UUID().uuidString
        tokens[key] = token; routes[token] = HMCacheTransport.Route(url: url, item: item)
        let ext = url == item.url && item.format == .hls ? "m3u8" : (url.pathExtension.isEmpty ? "bin" : url.pathExtension)
        return URL(string: "http://127.0.0.1:\(listeningPort)/\(token)/media.\(ext)")!
    }
    func prune(keeping items: Set<HMMediaItem>) {
        lock.lock(); defer { lock.unlock() }
        allowedItems = Set(items.map(identity))
        let updated = Dictionary(uniqueKeysWithValues: items.map { (identity($0), $0) })
        routes = routes.compactMapValues { route in
            updated[identity(route.item)].map { item in
                let isRoot = route.item.url.map { HMCacheKey.canonical($0, ignoring: signingParameters) } == HMCacheKey.canonical(route.url, ignoring: signingParameters)
                return HMCacheTransport.Route(url: isRoot ? (item.url ?? route.url) : route.url, item: item)
            }
        }
        let valid = Set(routes.keys); tokens = tokens.filter { valid.contains($0.value) }
    }
}
#endif
