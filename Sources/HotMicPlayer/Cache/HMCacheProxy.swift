#if canImport(Network) && !os(macOS)
import Foundation
import Network

/// One loopback HTTP transport for MP4 and HLS. Bound exclusively to loopback,
/// opaque routes, bounded upstream ranges, no URLSession implicit disk cache.
actor HMCacheTransport {
    struct Route { let url: URL; let item: HMMediaItem }
    struct Transfer { let data: Data; let total: Int; let mime: String; let base: URL; let start: Int }
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
    private var retainedItems: [HMMediaItem] = []
    private var resourceOwners: [String: Set<String>] = [:]
    private var inFlightResources: [String: Int] = [:]
    private var retiredWaste = 0
    private struct StreamState { var cursor: Int; var buffer = Data(); let total: Int; let mime: String; let base: URL }
    private var streams: [UUID: StreamState] = [:]
    private var eventDelivery: Task<Void, Never>?
    private var connections: [UUID: NWConnection] = [:]
    private var responseTasks: [UUID: Task<Void, Never>] = [:]
    private var prefetchTask: Task<Void, Never>?
    private var workEpoch = HMPrefetchEpoch()
    private var generation: Int { workEpoch.generation }
    private var prefetched: Set<String> = []
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
        if config.strategy.usesDataCache { await cache.configure(capacity: config.cacheCapacityBytes, pinned: Set(retainedItems.map { key($0.url) })) }
    }
    func start() async -> Bool {
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
            port = listener?.port?.rawValue ?? 0; previousPort = port; state.setPort(port); resolveStart(port != 0)
        case .failed: previousPort = 0; resolveStart(false)
        case .cancelled: resolveStart(false)
        default: break
        }
    }
    private func startTimedOut(_ identifier: UUID) { if identifier == listenerID, port == 0 { resolveStart(false) } }
    nonisolated func url(for item: HMMediaItem) -> URL {
        if state.port == 0 { Task { _ = await start() } }
        guard !item.url.isFileURL, item.streamKind != .live else { return item.url }
        return state.url(item.url, item: item)
    }
    private func proxyURL(_ url: URL, item: HMMediaItem) -> URL { state.url(url, item: item) }
    private func key(_ url: URL) -> String { HMCacheKey.canonical(url, ignoring: configuration.volatileSigningQueryParameters) }
    func retainWindow(_ items: [HMMediaItem]) {
        retainedItems = items
        let ids = Set(items.map(\.id))
        played.formIntersection(ids)
        warmDeliveries = warmDeliveries.filter { ids.contains($0.key) }
        let retained = Set(items.map { key($0.url) })
        // Completed resources can be folded into one waste counter as soon as
        // their route leaves the window. Active/canceling requests retain their
        // accounting until completion and are revisited on the next commit.
        let activeKeys = Set(state.allURLs().map { key($0) }).union(inFlightResources.keys)
        for resource in Array(resourceOwners.keys) where !activeKeys.contains(resource) && resourceOwners[resource, default: []].isDisjoint(with: retained) && prefetchTask == nil && retiringPrefetch.isEmpty {
            retiredWaste += max(0, (prefetchedNetwork.removeValue(forKey: resource) ?? 0) - HMRangeCoverage.overlap(prefetchRanges[resource] ?? [], playedRanges[resource] ?? []))
            prefetchRanges[resource] = nil; playedRanges[resource] = nil; resourceOwners[resource] = nil
        }
        prefetched.formIntersection(retained)
        memoryPlaylists = memoryPlaylists.filter { ProcessInfo.processInfo.systemUptime - $0.value.1 < 3 && state.contains(url: $0.value.0.base) }
    }
    func markPlayed(_ item: HMMediaItem) {
        played.insert(item.id)
        for (key, ranges) in warmDeliveries.removeValue(forKey: item.id) ?? [:] { playedRanges[key] = HMRangeCoverage.union((playedRanges[key] ?? []) + ranges) }
        // Repeated playlist IDs share a media path and disk entries.
        let owner = key(item.url)
        Task { await cache.markPlayed(owner) }
    }
    func cancelPrefetch() {
        workEpoch.cancel()
        if let task = prefetchTask {
            let id = UUID(); task.cancel(); retiringPrefetch[id] = task
            Task { await task.value; removeRetiring(id) }
        }
        prefetchTask = nil
    }
    private func removeRetiring(_ id: UUID) { retiringPrefetch[id] = nil; retainWindow(retainedItems) }
    func prefetch(_ items: [HMMediaItem], keeping: [HMMediaItem]) {
        let identity = configuration.fingerprint + "|" + items.map { $0.id + $0.url.absoluteString }.joined(separator: "|") + "|" + keeping.map(\.id).joined(separator: "|")
        guard port != 0, !disabled, configuration.strategy.usesDataCache, !workEpoch.matches(identity) else { return }
        cancelPrefetch()
        guard let epoch = workEpoch.begin(identity) else { return }
        let kept = Set(keeping.map(\.id))
        warmDeliveries = warmDeliveries.filter { kept.contains($0.key) }
        memoryPlaylists = memoryPlaylists.filter { ProcessInfo.processInfo.systemUptime - $0.value.1 < 3 && state.contains(url: $0.value.0.base) }

        let config = configuration
        prefetchTask = Task { [weak self] in await self?.runPrefetch(items, keeping: keeping, config: config, epoch: epoch) }
    }
    private func runPrefetch(_ items: [HMMediaItem], keeping: [HMMediaItem], config: HMPlayerConfiguration, epoch: Int) async {
        guard !Task.isCancelled, epoch == generation else { return }
        await cache.configure(capacity: config.cacheCapacityBytes, pinned: Set(keeping.map { key($0.url) }))
        cachedBytes = await cache.sizes(); state.setBytes(cachedBytes)
        prefetched.formIntersection(Set(cachedBytes.keys))
        for item in items where !item.url.isFileURL && item.streamKind != .live {
            guard !Task.isCancelled, epoch == generation else { break }
            let identity = key(item.url)
            guard !prefetched.contains(identity) else { continue }
            do {
                try await prefetchWithRetry(item, budget: max(0, min(HMPrefetchPolicy.maximumBytesPerItem, config.prefetch.bytesPerItem)), seconds: config.prefetch.secondsPerItem, epoch: epoch)
                if !Task.isCancelled { prefetched.insert(identity) }
            } catch {
                if !Task.isCancelled { emit(.prefetchError, item: item, properties: ["message": error.localizedDescription, "epoch": String(epoch), "attempt_limit": "3"]) }
            }
            cachedBytes[identity] = await cache.bytes(for: identity); state.setBytes(cachedBytes)
        }
        if epoch == generation { prefetchTask = nil; retainWindow(retainedItems) }
    }
    private func prefetchWithRetry(_ item: HMMediaItem, budget: Int, seconds: Double?, epoch: Int) async throws {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            guard epoch == generation else { throw CancellationError() }
            do { try await prefetchItem(item, budget: budget, seconds: seconds); return }
            catch {
                guard attempt < 2, !(error is CancellationError) else { throw error }
                try await Task.sleep(for: .seconds(attempt == 0 ? 0.5 : 2))
            }
        }
    }
    private func prefetchItem(_ item: HMMediaItem, budget: Int, seconds: Double?) async throws {
        guard budget > 0, seconds == nil || seconds! > 0 else { return }
        var remaining = budget
        if item.url.pathExtension.lowercased() != "m3u8" {
            var cursor = 0
            while cursor < remaining {
                let t = try await fetch(item.url, item: item, start: cursor, count: min(512 * 1024, remaining - cursor), prefetch: true)
                cursor += t.data.count
                remaining = min(remaining, t.total)
                if let seconds, let duration = item.durationHint, duration > 0 {
                    remaining = min(remaining, max(0, Int(Double(t.total) * min(1, max(0, seconds) / duration))))
                }
                guard !t.data.isEmpty else { break }
            }
            return
        }
        var url = item.url
        var mediaText: String?
        // Master -> selected rendition -> init and first segment(s). Other
        // renditions are rewritten on demand, never prefetched in parallel.
        for _ in 0..<4 {
            let t = try await fetch(url, item: item, start: 0, count: min(remaining, url.pathExtension == "m3u8" ? 64 * 1024 : remaining), prefetch: true)
            remaining -= t.data.count
            guard url.pathExtension == "m3u8", let text = String(data: t.data, encoding: .utf8) else { return }
            if text.contains("#EXT-X-STREAM-INF") {
                let lines = text.components(separatedBy: .newlines)
                var choices: [(Double, URL)] = []
                for i in lines.indices where lines[i].hasPrefix("#EXT-X-STREAM-INF") && i + 1 < lines.count {
                    let bandwidth = lines[i].components(separatedBy: "BANDWIDTH=").last?.split(separator: ",").first.flatMap { Double($0) } ?? 0
                    if let u = URL(string: lines[i + 1], relativeTo: t.base)?.absoluteURL { choices.append((bandwidth, u)) }
                }
                let cap = configuration.startupPeakBitRate
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
        let playlist = url.pathExtension.lowercased() == "m3u8"
        if playlist, let (hit, time) = memoryPlaylists[url.absoluteString], ProcessInfo.processInfo.systemUptime - time < 3 {
            if !prefetch {
                recordDelivery(key: key, item: item, start: start, count: hit.data.count)
                emit(.transfer, item: item, metrics: ["cache_bytes": Double(hit.data.count), "network_bytes": 0])
            }
            return hit
        }
        let owner = self.key(item.url)
        if !playlist, configuration.strategy.usesDataCache, let total = await cache.total(for: key) {
            let end = min(total - 1, start + count - 1)
            if end >= start, let hit = await (prefetch || url.pathExtension == "m3u8" ? cache.read(key: key, range: HMByteRange(start: start, end: end)) : cache.available(key: key, start: start, count: count)) {
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
        do { result = try await HMHTTPFetcher(limit: count).load(request) }
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
    private func releaseResource(_ key: String) {
        if let count = inFlightResources[key], count > 1 { inFlightResources[key] = count - 1 }
        else { inFlightResources[key] = nil }
        retainWindow(retainedItems)
    }
    private func recordDelivery(key: String, item: HMMediaItem, start: Int, count: Int) {
        let range = HMByteRange(start: start, end: start + count - 1)
        resourceOwners[key, default: []].insert(self.key(item.url))
        if played.contains(item.id) { playedRanges[key] = HMRangeCoverage.union((playedRanges[key] ?? []) + [range]) }
        else { warmDeliveries[item.id, default: [:]][key] = HMRangeCoverage.union((warmDeliveries[item.id]?[key] ?? []) + [range]) }
    }
    private func account(_ bytes: Int, url: URL, item: HMMediaItem, prefetch: Bool) {
        resourceOwners[key(url), default: []].insert(key(item.url))
        if prefetch { prefetchedNetwork[key(url), default: 0] += bytes }
        emit(.transfer, item: item, metrics: ["network_bytes": Double(bytes), "cache_bytes": 0, "prefetch_bytes": prefetch ? Double(bytes) : 0], properties: ["resource": HMCacheKey.hash(key(url))])
    }
    private func accept(_ connection: NWConnection) {
        guard !isFinishing else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { await self?.close(id) } }
            if case .cancelled = state { Task { await self?.close(id) } }
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
        let rangeHeader = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }.map { $0.dropFirst(6).trimmingCharacters(in: .whitespaces) }
        do {
            if route.url.pathExtension == "m3u8" {
                let t = try await fetch(route.url, item: route.item, start: 0, count: 512 * 1024, prefetch: false)
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
            try await sendBlock(connection, data: Data(head.utf8))
            if request[0] != "HEAD" {
                var cursor = range.start
                while cursor <= range.end {
                    try Task.checkCancellation()
                    let t = try await fetch(route.url, item: route.item, start: cursor, count: min(512 * 1024, range.end - cursor + 1), prefetch: false)
                    guard !t.data.isEmpty else { throw URLError(.badServerResponse) }
                    try await sendBlock(connection, data: t.data)
                    cursor += t.data.count
                }
            }
            close(id)
        } catch {
            if !Task.isCancelled {
                // A client closing a completed AVFoundation probe is normal.
                let underlying = (error as? HMHTTPFetcher.Failure)?.underlying ?? error
                if !(underlying is NWError), (underlying as NSError).code != NSURLErrorCancelled { emit(.transportError, item: route.item, properties: ["message": error.localizedDescription]) }
                close(id)
            }
        }
    }
    private func stream(_ route: Route, range: String?, headOnly: Bool, connection: NWConnection) async throws {
        let streamID = UUID()
        let resource = key(route.url); inFlightResources[resource, default: 0] += 1
        defer { releaseResource(resource) }
        var request = URLRequest(url: route.url)
        request.httpMethod = headOnly ? "HEAD" : "GET"
        request.setValue(range, forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let fetcher = HMHTTPFetcher(limit: Int.max, headers: { [weak self] response in
            guard let self else { throw CancellationError() }
            await self.beginStream(streamID, response: response)
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
            await self.account(bytes.count, url: route.url, item: route.item, prefetch: false)
            try await self.sendBlock(connection, data: bytes)
            await self.cacheStream(streamID, bytes: bytes, route: route)
        })
        do { _ = try await fetcher.load(request); await cacheStream(streamID, bytes: Data(), route: route, finishing: true) }
        catch { await cacheStream(streamID, bytes: Data(), route: route, finishing: true); throw error }
    }
    private func beginStream(_ id: UUID, response: HTTPURLResponse) {
        guard response.statusCode == 200 || response.statusCode == 206 else { return }
        let range = response.value(forHTTPHeaderField: "Content-Range")
        let total = range?.split(separator: "/").last.flatMap { Int($0) } ?? Int(response.expectedContentLength)
        let cursor = range?.dropFirst(6).split(separator: "-").first.flatMap { Int($0) } ?? 0
        streams[id] = StreamState(cursor: cursor, total: total, mime: response.mimeType ?? HMCacheKey.mime(response.url!), base: response.url!)
    }
    private func cacheStream(_ id: UUID, bytes: Data, route: Route, finishing: Bool = false) async {
        guard var stream = streams[id] else { return }
        if !bytes.isEmpty { recordDelivery(key: key(route.url), item: route.item, start: stream.cursor + stream.buffer.count, count: bytes.count) }
        stream.buffer.append(bytes)
        while stream.buffer.count >= 512 * 1024 || (finishing && !stream.buffer.isEmpty) {
            let size = min(512 * 1024, stream.buffer.count)
            let chunk = Data(stream.buffer.prefix(size)); stream.buffer.removeFirst(size)
            if configuration.strategy.usesDataCache, stream.total > 0 {
                await cache.put(key: key(route.url), start: stream.cursor, data: chunk, total: stream.total, mime: stream.mime, base: stream.base,
                                owner: key(route.item.url), prefetched: false, played: played.contains(route.item.id))
            }
            stream.cursor += size
        }
        streams[id] = finishing ? nil : stream
        if finishing, configuration.strategy.usesDataCache {
            let owner = key(route.item.url); cachedBytes[owner] = await cache.bytes(for: owner); state.setBytes(cachedBytes)
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
    private func close(_ id: UUID) {
        responseTasks.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.cancel()
    }
    func finish() async -> Int {
        isFinishing = true
        listener?.cancel(); port = 0; state.setPort(0)
        cancelPrefetch()
        let tasks = Array(responseTasks.values) + Array(retiringPrefetch.values)
        retiringPrefetch.removeAll()
        for id in Array(connections.keys) { close(id) }
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
    func url(for item: HMMediaItem) -> URL { transport.url(for: item) }
    func cachedByteCount(for item: HMMediaItem) -> Int {
        configuration.strategy.usesDataCache && transport.state.port != 0 ? transport.state.bytes(for: HMCacheKey.canonical(item.url, ignoring: configuration.volatileSigningQueryParameters)) : 0
    }
    func retainWindow(_ items: [HMMediaItem]) {
        transport.state.prune(keeping: Set(items.map(\.id)))
        enqueue { await $0.retainWindow(items) }
    }
    func markPlayed(_ item: HMMediaItem) { enqueue { await $0.markPlayed(item) } }
    func cancelPrefetch() { enqueue { await $0.cancelPrefetch() } }
    func prefetch(_ items: [HMMediaItem], keeping: [HMMediaItem]) { enqueue { await $0.prefetch(items, keeping: keeping) } }
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
    private var allowedIDs: Set<String>?
    var port: UInt16 { lock.lock(); defer { lock.unlock() }; return listeningPort }
    func setPort(_ value: UInt16) { lock.lock(); listeningPort = value; lock.unlock() }
    func setBytes(_ value: [String: Int]) { lock.lock(); cachedBytes = value; lock.unlock() }
    func bytes(for key: String) -> Int { lock.lock(); defer { lock.unlock() }; return cachedBytes[key] ?? 0 }
    func route(_ token: String) -> HMCacheTransport.Route? { lock.lock(); defer { lock.unlock() }; return routes[token] }
    func allURLs() -> [URL] { lock.lock(); defer { lock.unlock() }; return routes.values.map(\.url) }
    func contains(url: URL) -> Bool { lock.lock(); defer { lock.unlock() }; return routes.values.contains { $0.url == url } }
    func url(_ url: URL, item: HMMediaItem) -> URL {
        lock.lock(); defer { lock.unlock() }
        guard listeningPort != 0, allowedIDs?.contains(item.id) != false else { return url }
        let key = item.id + "|" + url.absoluteString
        let token = tokens[key] ?? UUID().uuidString
        tokens[key] = token; routes[token] = HMCacheTransport.Route(url: url, item: item)
        return URL(string: "http://127.0.0.1:\(listeningPort)/\(token)/media.\(url.pathExtension.isEmpty ? "bin" : url.pathExtension)")!
    }
    func prune(keeping ids: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        allowedIDs = ids
        routes = routes.filter { ids.contains($0.value.item.id) }
        let valid = Set(routes.keys); tokens = tokens.filter { valid.contains($0.value) }
    }
}
#endif
