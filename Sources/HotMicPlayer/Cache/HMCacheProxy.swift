#if canImport(Network) && !os(macOS)
import Foundation
import Network

/// One loopback HTTP transport for MP4 and HLS. Bound exclusively to loopback,
/// opaque routes, bounded upstream ranges, no URLSession implicit disk cache.
actor HMCacheTransport {
    struct Route { let url: URL; let item: HMMediaItem }
    struct Transfer { let data: Data; let total: Int; let mime: String; let base: URL; let start: Int }
    private var startup: Task<Bool, Never>?
    private var playlistOwners: Set<String> = []
    private var listener: NWListener?
    private var listenerID = UUID()
    private var startWaiters: [CheckedContinuation<Bool, Never>] = []
    private var disabled = false
    private var previousPort: UInt16 = 0
    nonisolated let state = HMProxyState()
    private let queue = DispatchQueue(label: "com.hotmic.cache.http")
    private let cache: HMDiskCache
    private var port: UInt16 = 0
    private var isFinishing = false
    private var played: Set<String> = []
    private var playbackUrgent = true
    private var priorityItem: HMMediaItem?
    private var priorityWaiters: [UUID: (HMMediaItem, CheckedContinuation<Void, Error>)] = [:]
    private var retainedItems: [HMMediaItem] = []
    private var resourceOwners: [String: Set<String>] = [:]
    private var inFlightResources: [String: Int] = [:]
    private var retiredWaste = 0
    private struct StreamState { var cursor: Int; var buffer = Data(); let total: Int; let mime: String; let base: URL }
    private var streams: [UUID: StreamState] = [:]
    private var eventDelivery: Task<Void, Never>?
    private var connections: [UUID: NWConnection] = [:]
    private var responseTasks: [UUID: Task<Void, Never>] = [:]
    private var responseItems: [UUID: HMMediaItem] = [:]
    private var prefetchTask: Task<Void, Never>?
    private var workEpoch = HMPrefetchEpoch()
    private var generation: Int { workEpoch.generation }
    private var prefetched: [String: String] = [:]
    private var prefetchedNetwork: [String: Int] = [:]
    private var prefetchRanges: [String: [HMByteRange]] = [:]
    private var playedRanges: [String: [HMByteRange]] = [:]
    private var warmDeliveries: [String: [String: [HMByteRange]]] = [:]
    private var retiringPrefetch: [UUID: Task<Void, Never>] = [:]
    private var memoryPlaylists: [String: (Transfer, TimeInterval)] = [:]
    private(set) var cachedBytes: [String: Int] = [:]
    var configuration: HMPlayerConfiguration
    var onEvent: (@MainActor @Sendable (HMPlaybackEvent, HMMediaItem) -> Void)?

    init(configuration: HMPlayerConfiguration, directory: URL? = nil) throws {
        self.configuration = configuration
        let folder = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("HotMicPlayer-v1")
        cache = HMDiskCache.shared(directory: folder, capacity: configuration.cacheCapacityBytes)
    }
    func setEventHandler(_ handler: @escaping @MainActor @Sendable (HMPlaybackEvent, HMMediaItem) -> Void) { onEvent = handler }
    func updateConfiguration(_ config: HMPlayerConfiguration) async {
        configuration = config; cancelPrefetch()
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
    private func key(_ url: URL) -> String { HMCacheKey.canonical(url, ignoring: configuration.volatileSigningQueryParameters) }
    func retainWindow(_ items: [HMMediaItem]) {
        retainedItems = items
        let ids = Set(items.map(\.id))
        for (id, item) in responseItems where !items.contains(item) { close(id, reason: "outside-window") }
        played.formIntersection(ids)
        warmDeliveries = warmDeliveries.filter { ids.contains($0.key) }
        let retained = Set(items.compactMap(\.url).map { key($0) })
        // Completed resources can be folded into one waste counter as soon as
        // their route leaves the window. Active/canceling requests retain their
        // accounting until completion and are revisited on the next commit.
        let activeKeys = Set(state.allURLs().map { key($0) }).union(inFlightResources.keys)
        for resource in Array(resourceOwners.keys) where !activeKeys.contains(resource) && resourceOwners[resource, default: []].isDisjoint(with: retained) && prefetchTask == nil && retiringPrefetch.isEmpty {
            retiredWaste += max(0, (prefetchedNetwork.removeValue(forKey: resource) ?? 0) - HMRangeCoverage.overlap(prefetchRanges[resource] ?? [], playedRanges[resource] ?? []))
            prefetchRanges[resource] = nil; playedRanges[resource] = nil; resourceOwners[resource] = nil
        }
        prefetched = prefetched.filter { retained.contains($0.key) }
        memoryPlaylists = memoryPlaylists.filter { ProcessInfo.processInfo.systemUptime - $0.value.1 < max(0, configuration.playlistTTL) && state.contains(url: $0.value.0.base) }
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
        played.insert(item.id)
        for (key, ranges) in warmDeliveries.removeValue(forKey: item.id) ?? [:] { playedRanges[key] = HMRangeCoverage.union((playedRanges[key] ?? []) + ranges) }
        // Repeated playlist IDs share a media path and disk entries.
        let owner = key(url)
        Task { await cache.markPlayed(owner) }
    }
    /// Native playback and explicit prefixes share the origin's capacity, even
    /// when URLSession uses separate connection pools. Cancel explicit prefixes
    /// and hold native neighbours with streaming backpressure, preserving their
    /// proxy connection and cache path until the current item displays/recovers.
    func prioritizePlayback(_ item: HMMediaItem, urgent: Bool) {
        priorityItem = item; playbackUrgent = urgent
        if urgent { cancelPrefetch() }
        for (id, (owner, waiter)) in priorityWaiters where !urgent || owner == item {
            priorityWaiters[id] = nil
            emit(.transfer, item: owner, metrics: ["proxy_priority_resume": 1])
            waiter.resume()
        }
    }
    private func waitForPlaybackPriority(_ item: HMMediaItem) async throws {
        try Task.checkCancellation()
        guard !isFinishing else { throw CancellationError() }
        guard playbackUrgent, let priorityItem, priorityItem != item else { return }
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
    #endif
    func cancelPrefetch() {
        workEpoch.cancel()
        if let task = prefetchTask {
            let id = UUID(); task.cancel(); retiringPrefetch[id] = task
            Task { await task.value; removeRetiring(id) }
        }
        prefetchTask = nil
    }
    private func removeRetiring(_ id: UUID) { retiringPrefetch[id] = nil; retainWindow(retainedItems) }
    func prefetch(_ items: [HMMediaItem], keeping: [HMMediaItem], plan: HMPrefetchPlan) {
        let identity = configuration.fingerprint + "|" + plan.workIdentity + "|" + items.map { $0.id + ($0.url?.absoluteString ?? "") }.joined(separator: "|") + "|" + keeping.map(\.id).joined(separator: "|")
        guard port != 0, !disabled, !playbackUrgent, configuration.strategy.usesDataCache, !plan.paused, plan.concurrency > 0, !workEpoch.matches(identity) else { return }
        cancelPrefetch()
        guard let epoch = workEpoch.begin(identity) else { return }
        let kept = Set(keeping.map(\.id))
        warmDeliveries = warmDeliveries.filter { kept.contains($0.key) }
        memoryPlaylists = memoryPlaylists.filter { ProcessInfo.processInfo.systemUptime - $0.value.1 < max(0, configuration.playlistTTL) && state.contains(url: $0.value.0.base) }

        let config = configuration
        prefetchTask = Task(priority: .utility) { [weak self] in await self?.runPrefetch(items, keeping: keeping, config: config, plan: plan, epoch: epoch) }
    }
    private func runPrefetch(_ items: [HMMediaItem], keeping: [HMMediaItem], config: HMPlayerConfiguration, plan: HMPrefetchPlan, epoch: Int) async {
        guard !Task.isCancelled, epoch == generation else { return }
        await cache.configure(capacity: config.cacheCapacityBytes, pinned: Set(keeping.compactMap(\.url).map { key($0) }))
        cachedBytes = await cache.sizes(); state.setBytes(cachedBytes)
        prefetched = prefetched.filter { cachedBytes[$0.key] != nil }
        // Sliding window admits nearest entries first. Default concurrency is one.
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func add(_ item: HMMediaItem) { group.addTask { await self.prefetchEntry(item, plan: plan, epoch: epoch) } }
            while next < min(items.count, plan.concurrency) { add(items[next]); next += 1 }
            while await group.next() != nil {
                guard !Task.isCancelled, epoch == generation else { group.cancelAll(); break }
                if next < items.count { add(items[next]); next += 1 }
            }
        }
        if epoch == generation { prefetchTask = nil; retainWindow(retainedItems) }
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
            if !Task.isCancelled, epoch == generation {
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
                guard attempt < 2, !(error is CancellationError) else { throw error }
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
        var url = mediaURL
        var mediaText: String?
        // Master -> selected rendition -> init and first segment(s). Other
        // renditions are rewritten on demand, never prefetched in parallel.
        for _ in 0..<4 {
            let t = try await fetch(url, item: item, start: 0, count: min(remaining, 64 * 1024), prefetch: true)
            remaining -= t.data.count
            guard let text = String(data: t.data, encoding: .utf8), text.hasPrefix("#EXTM3U") else { return }
            if text.contains("#EXT-X-STREAM-INF") {
                let lines = text.components(separatedBy: .newlines)
                var choices: [(Double, URL)] = []
                for i in lines.indices where lines[i].hasPrefix("#EXT-X-STREAM-INF") && i + 1 < lines.count {
                    let bandwidth = lines[i].components(separatedBy: "BANDWIDTH=").last?.split(separator: ",").first.flatMap { Double($0) } ?? 0
                    if let u = URL(string: lines[i + 1], relativeTo: t.base)?.absoluteURL { choices.append((bandwidth, u)) }
                }
                let cap = bitRate
                let sorted = choices.sorted { $0.0 < $1.0 }
                guard let chosen = (cap > 0 ? sorted.last(where: { $0.0 <= cap }) : sorted.last) ?? sorted.first else { return }
                url = chosen.1
            } else { mediaText = text; url = t.base; break }
            guard remaining > 0 else { return }
        }
        guard let text = mediaText else { return }
        var elapsed = 0.0
        var segmentDuration = 0.0
        for line in text.components(separatedBy: .newlines) {
            try Task.checkCancellation()
            if line.hasPrefix("#EXTINF:") { segmentDuration = Double(line.dropFirst(8).split(separator: ",").first ?? "0") ?? 0 }
            let refs = HMPlaylist.references(line, base: url)
            for ref in refs {
                guard remaining > 0 else { return }
                if !line.hasPrefix("#"), let seconds, elapsed >= seconds { return }
                var cursor = 0
                while remaining > 0 {
                    let t = try await fetch(ref, item: item, start: cursor, count: min(512 * 1024, remaining), prefetch: true)
                    remaining -= t.data.count; cursor += t.data.count
                    if t.data.isEmpty || cursor >= t.total { break }
                }
                if !line.hasPrefix("#") { elapsed += segmentDuration }
            }
        }
    }
    private func fetch(_ url: URL, item: HMMediaItem, start: Int, count: Int, prefetch: Bool) async throws -> Transfer {
        try Task.checkCancellation()
        guard count > 0, ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw URLError(.unsupportedURL) }
        let key = key(url)
        inFlightResources[key, default: 0] += 1
        defer { releaseResource(key) }
        let playlist = url.pathExtension.lowercased() == "m3u8" || (url == item.url && item.format == .hls)
        if playlist, let (hit, time) = memoryPlaylists[url.absoluteString], ProcessInfo.processInfo.systemUptime - time < max(0, configuration.playlistTTL) {
            if !prefetch {
                recordDelivery(key: key, item: item, start: start, count: hit.data.count)
                emit(.transfer, item: item, metrics: ["cache_bytes": Double(hit.data.count), "network_bytes": 0])
            }
            return hit
        }
        guard let mediaURL = item.url else { throw URLError(.unsupportedURL) }
        let owner = self.key(mediaURL)
        if !playlist, configuration.strategy.usesDataCache, let total = await cache.total(for: key) {
            let end = min(total - 1, start + count - 1)
            if end >= start, let hit = await cache.available(key: key, start: start, count: count) {
                if !prefetch {
                    recordDelivery(key: key, item: item, start: start, count: hit.data.count)
                    emit(.transfer, item: item, metrics: ["cache_bytes": Double(hit.data.count), "network_bytes": 0])
                }
                return Transfer(data: hit.data, total: hit.total, mime: hit.mime, base: hit.base, start: start)
            }
        }
        var request = URLRequest(url: url)
        request.setValue("bytes=\(start)-\(start + count - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let result: HMHTTPFetcher.Result
        do { result = try await HMHTTPFetcher(limit: count, priority: prefetch ? URLSessionTask.lowPriority : URLSessionTask.highPriority,
            measurement: measurementHandler(item, speculative: prefetch)).load(request) }
        catch {
            if let failure = error as? HMHTTPFetcher.Failure { account(failure.received, url: url, item: item, prefetch: prefetch) }
            throw error
        }
        let http = result.response
        let contentRange = http.value(forHTTPHeaderField: "Content-Range")
        let total = contentRange?.split(separator: "/").last.flatMap { Int($0) } ?? Int(http.expectedContentLength)
        guard total > 0, start < total, http.statusCode != 200 || start == 0 else { throw URLError(.badServerResponse) }
        if http.statusCode == 206 {
            guard contentRange?.hasPrefix("bytes \(start)-") == true else { throw URLError(.badServerResponse) }
        }
        let mime = http.mimeType ?? HMCacheKey.mime(url)
        let data = result.data
        account(result.received, url: url, item: item, prefetch: prefetch)
        if prefetch, !data.isEmpty { prefetchRanges[key] = HMRangeCoverage.union((prefetchRanges[key] ?? []) + [HMByteRange(start: start, end: start + data.count - 1)]) }
        else if !data.isEmpty { recordDelivery(key: key, item: item, start: start, count: data.count) }
        try Task.checkCancellation()
        if !playlist, configuration.strategy.usesDataCache {
            await cache.put(key: key, start: start, data: data, total: total, mime: mime, base: http.url ?? url, owner: owner,
                            prefetched: prefetch, played: played.contains(item.id))
            cachedBytes[owner] = await cache.bytes(for: owner); state.setBytes(cachedBytes)
        }
        let transfer = Transfer(data: data, total: total, mime: mime, base: http.url ?? url, start: start)
        if playlist, data.count == total { memoryPlaylists[url.absoluteString] = (transfer, ProcessInfo.processInfo.systemUptime) }
        return transfer
    }
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
    private func releaseResource(_ key: String) {
        if let count = inFlightResources[key], count > 1 { inFlightResources[key] = count - 1 }
        else { inFlightResources[key] = nil }
    }
    private func recordDelivery(key: String, item: HMMediaItem, start: Int, count: Int) {
        let range = HMByteRange(start: start, end: start + count - 1)
        if let url = item.url { resourceOwners[key, default: []].insert(self.key(url)) }
        if played.contains(item.id) { playedRanges[key] = HMRangeCoverage.union((playedRanges[key] ?? []) + [range]) }
        else { warmDeliveries[item.id, default: [:]][key] = HMRangeCoverage.union((warmDeliveries[item.id]?[key] ?? []) + [range]) }
    }
    private func account(_ bytes: Int, url: URL, item: HMMediaItem, prefetch: Bool) {
        if let mediaURL = item.url { resourceOwners[key(url), default: []].insert(key(mediaURL)) }
        if prefetch { prefetchedNetwork[key(url), default: 0] += bytes }
        emit(.transfer, item: item, metrics: ["network_bytes": Double(bytes), "cache_bytes": 0, "prefetch_bytes": prefetch ? Double(bytes) : 0], properties: ["resource": HMCacheKey.hash(key(url))])
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
                try await stream(route, range: rangeHeader, headOnly: request[0] == "HEAD", connection: connection)
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
                        recordDelivery(key: key, item: route.item, start: cursor, count: hit.data.count)
                        emit(.transfer, item: route.item, metrics: ["cache_bytes": Double(hit.data.count), "network_bytes": 0])
                        try await sendBlock(connection, data: hit.data)
                        cursor += hit.data.count
                    } else {
                        // Knowing the total (often from AVPlayer's two-byte probe)
                        // must not turn a miss into a fully buffered 512 KiB fetch.
                        // Stream the missing suffix immediately, independently of
                        // any cancelled/overlapping speculative range.
                        let delivered = try await stream(route, range: "bytes=\(cursor)-\(range.end)", headOnly: false,
                                         connection: connection, sendHeaders: false, limit: range.end - cursor + 1)
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
                if !(underlying is NWError), (underlying as NSError).code != NSURLErrorCancelled { emit(.transportError, item: route.item, properties: ["message": error.localizedDescription]) }
                close(id, reason: "response-error")
            }
        }
    }
    @discardableResult
    private func stream(_ route: Route, range: String?, headOnly: Bool, connection: NWConnection, sendHeaders: Bool = true, limit: Int = Int.max) async throws -> Int {
        let streamID = UUID()
        let resource = key(route.url); inFlightResources[resource, default: 0] += 1
        defer { releaseResource(resource) }
        var request = URLRequest(url: route.url)
        request.httpMethod = headOnly ? "HEAD" : "GET"
        request.setValue(range, forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        try await waitForPlaybackPriority(route.item)
        let fetcher = HMHTTPFetcher(limit: limit, priority: played.contains(route.item.id) ? URLSessionTask.highPriority : URLSessionTask.defaultPriority,
            measurement: measurementHandler(route.item, speculative: !played.contains(route.item.id)), headers: { [weak self] response in
            guard let self else { throw CancellationError() }
            try await self.waitForPlaybackPriority(route.item)
            await self.beginStream(streamID, response: response)
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
            account(result.received, url: route.url, item: route.item, prefetch: false)
            await cacheStream(streamID, bytes: Data(), route: route, finishing: true)
            return result.delivered
        } catch {
            if let failure = error as? HMHTTPFetcher.Failure { account(failure.received, url: route.url, item: route.item, prefetch: false) }
            await cacheStream(streamID, bytes: Data(), route: route, finishing: true); throw error
        }
    }
    private func beginStream(_ id: UUID, response: HTTPURLResponse) {
        guard response.statusCode == 200 || response.statusCode == 206 else { return }
        let range = response.value(forHTTPHeaderField: "Content-Range")
        let total = range?.split(separator: "/").last.flatMap { Int($0) } ?? Int(response.expectedContentLength)
        let cursor = range?.dropFirst(6).split(separator: "-").first.flatMap { Int($0) } ?? 0
        streams[id] = StreamState(cursor: cursor, total: total, mime: response.mimeType ?? HMCacheKey.mime(response.url!), base: response.url!)
    }
    private func cacheStream(_ id: UUID, bytes: Data, route: Route, finishing: Bool = false) async {
        guard var stream = streams[id], let mediaURL = route.item.url else { return }
        if !bytes.isEmpty { recordDelivery(key: key(route.url), item: route.item, start: stream.cursor + stream.buffer.count, count: bytes.count) }
        stream.buffer.append(bytes)
        while stream.buffer.count >= 512 * 1024 || (finishing && !stream.buffer.isEmpty) {
            let size = min(512 * 1024, stream.buffer.count)
            let chunk = Data(stream.buffer.prefix(size)); stream.buffer.removeFirst(size)
            if configuration.strategy.usesDataCache, stream.total > 0 {
                await cache.put(key: key(route.url), start: stream.cursor, data: chunk, total: stream.total, mime: stream.mime, base: stream.base,
                                owner: key(mediaURL), prefetched: false, played: played.contains(route.item.id))
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
    func retainWindow(_ items: [HMMediaItem]) {
        guard retainedWindow != items else { return }
        retainedWindow = items
        transport.state.prune(keeping: Set(items))
        enqueue { await $0.retainWindow(items) }
    }
    func retainPlaylist(_ items: [HMMediaItem]) { guard retainedPlaylist != items else { return }; retainedPlaylist = items; enqueue { await $0.retainPlaylist(items) } }
    func markPlayed(_ item: HMMediaItem) { enqueue { await $0.markPlayed(item) } }
    func prioritizePlayback(_ item: HMMediaItem, urgent: Bool) {
        guard playbackPriority != item || playbackUrgent != urgent else { return }
        playbackPriority = item; playbackUrgent = urgent
        enqueue { await $0.prioritizePlayback(item, urgent: urgent) }
    }
    func cancelPrefetch() { enqueue { await $0.cancelPrefetch() } }
    func prefetch(_ items: [HMMediaItem], keeping: [HMMediaItem], plan: HMPrefetchPlan) { enqueue { await $0.prefetch(items, keeping: keeping, plan: plan) } }
    func finish() async -> Int { await commands?.value; return await transport.finish() }
}

/// Small synchronized route/port snapshot shared with the synchronous player
/// assignment path. Payloads and all network state remain actor isolated.
final class HMProxyState: @unchecked Sendable {
    private let lock = NSLock()
    private var listeningPort: UInt16 = 0
    private var routes: [String: HMCacheTransport.Route] = [:]
    private var tokens: [String: String] = [:]
    private var cachedBytes: [String: Int] = [:]
    private var allowedItems: Set<HMMediaItem>?
    var port: UInt16 { lock.lock(); defer { lock.unlock() }; return listeningPort }
    func setPort(_ value: UInt16) { lock.lock(); listeningPort = value; lock.unlock() }
    func setBytes(_ value: [String: Int]) { lock.lock(); cachedBytes = value; lock.unlock() }
    func bytes(for key: String) -> Int { lock.lock(); defer { lock.unlock() }; return cachedBytes[key] ?? 0 }
    func route(_ token: String) -> HMCacheTransport.Route? { lock.lock(); defer { lock.unlock() }; return routes[token] }
    func allURLs() -> [URL] { lock.lock(); defer { lock.unlock() }; return routes.values.map(\.url) }
    func contains(url: URL) -> Bool { lock.lock(); defer { lock.unlock() }; return routes.values.contains { $0.url == url } }
    func url(_ url: URL, item: HMMediaItem) -> URL {
        lock.lock(); defer { lock.unlock() }
        guard listeningPort != 0, allowedItems?.contains(item) != false else { return url }
        let key = item.id + "|" + url.absoluteString
        let token = tokens[key] ?? UUID().uuidString
        tokens[key] = token; routes[token] = HMCacheTransport.Route(url: url, item: item)
        let ext = url == item.url && item.format == .hls ? "m3u8" : (url.pathExtension.isEmpty ? "bin" : url.pathExtension)
        return URL(string: "http://127.0.0.1:\(listeningPort)/\(token)/media.\(ext)")!
    }
    func prune(keeping items: Set<HMMediaItem>) {
        lock.lock(); defer { lock.unlock() }
        allowedItems = items
        routes = routes.filter { items.contains($0.value.item) }
        let valid = Set(routes.keys); tokens = tokens.filter { valid.contains($0.value) }
    }
}
#endif
