#if canImport(Network) && !os(macOS)
import Foundation
import Network

/// One loopback HTTP transport for MP4 and HLS. Bound exclusively to loopback,
/// opaque routes, bounded upstream ranges, no URLSession implicit disk cache.
@MainActor
final class HMCacheProxy {
    struct Route { let url: URL; let item: HMMediaItem }
    struct Transfer { let data: Data; let total: Int; let mime: String; let base: URL; let start: Int }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.hotmic.cache.http")
    private let cache: HMDiskCache
    private var port: UInt16 = 0
    private var isFinishing = false
    private var routes: [String: Route] = [:]
    private var tokens: [String: String] = [:]
    private var played: Set<String> = []
    private var connections: [UUID: NWConnection] = [:]
    private var responseTasks: [UUID: Task<Void, Never>] = [:]
    private var prefetchTask: Task<Void, Never>?
    private var generation = 0
    private var prefetched: Set<String> = []
    private var prefetchedNetwork: [String: Int] = [:]
    private var prefetchRanges: [String: [HMByteRange]] = [:]
    private var playedRanges: [String: [HMByteRange]] = [:]
    private var warmDeliveries: [String: [String: [HMByteRange]]] = [:]
    private var retiringPrefetch: [Task<Void, Never>] = []
    private(set) var cachedBytes: [String: Int] = [:]
    var configuration: HMPlayerConfiguration
    var onEvent: ((HMPlaybackEvent, HMMediaItem) -> Void)?

    init(configuration: HMPlayerConfiguration, directory: URL? = nil) throws {
        self.configuration = configuration
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let folder = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("HotMicPlayer-v1")
        cache = HMDiskCache(directory: folder, capacity: configuration.strategy.usesDataCache ? configuration.cacheCapacityBytes : 0)
    }
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var finished = false
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, !finished else { return }
                    switch state {
                    case .ready:
                        finished = true; self.port = self.listener.port!.rawValue
                        continuation.resume()
                    case .failed(let error): finished = true; continuation.resume(throwing: error)
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: queue)
        }
        await cache.configure(capacity: configuration.strategy.usesDataCache ? configuration.cacheCapacityBytes : 0, pinned: [])
        cachedBytes = await cache.sizes()
    }
    func url(for item: HMMediaItem) -> URL {
        guard !item.url.isFileURL, item.streamKind != .live, port != 0 else { return item.url }
        return proxyURL(item.url, item: item)
    }
    private func proxyURL(_ url: URL, item: HMMediaItem) -> URL {
        let key = item.id + "|" + url.absoluteString
        let token: String
        if let t = tokens[key] { token = t }
        else { token = UUID().uuidString; tokens[key] = token; routes[token] = Route(url: url, item: item) }
        return URL(string: "http://localhost:\(port)/\(token)/media.\(url.pathExtension.isEmpty ? "bin" : url.pathExtension)")!
    }
    func cachedByteCount(for item: HMMediaItem) -> Int { configuration.strategy.usesDataCache ? cachedBytes[HMCacheKey.canonical(item.url)] ?? 0 : 0 }
    func markPlayed(_ item: HMMediaItem) {
        played.insert(item.id)
        for (key, ranges) in warmDeliveries.removeValue(forKey: item.id) ?? [:] { playedRanges[key, default: []] += ranges }
        // Repeated playlist IDs share a media path and disk entries.
        Task { await cache.markPlayed(HMCacheKey.canonical(item.url)) }
    }
    func cancelPrefetch() {
        generation += 1
        if let task = prefetchTask { task.cancel(); retiringPrefetch.append(task) }
        prefetchTask = nil
    }
    func prefetch(_ items: [HMMediaItem], keeping: [HMMediaItem]) {
        guard configuration.strategy.usesDataCache, prefetchTask == nil else { return }
        generation += 1
        let epoch = generation
        let config = configuration
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            await cache.configure(capacity: config.cacheCapacityBytes, pinned: Set(keeping.map { HMCacheKey.canonical($0.url) }))
            cachedBytes = await cache.sizes()
            prefetched.formIntersection(Set(cachedBytes.keys))
            for item in items where !item.url.isFileURL && item.streamKind != .live {
                guard !Task.isCancelled, epoch == generation else { break }
                let identity = HMCacheKey.canonical(item.url)
                guard !prefetched.contains(identity) else { continue }
                do {
                    try await prefetchItem(item, budget: max(0, config.prefetch.bytesPerItem), seconds: config.prefetch.secondsPerItem)
                    if !Task.isCancelled { prefetched.insert(identity) }
                } catch {
                    if !Task.isCancelled { emit(.prefetchError, item: item, properties: ["message": error.localizedDescription]) }
                }
                cachedBytes[identity] = await cache.bytes(for: identity)
            }
            if epoch == generation { prefetchTask = nil }
        }
    }
    private func prefetchItem(_ item: HMMediaItem, budget: Int, seconds: Double?) async throws {
        guard budget > 0 else { return }
        var remaining = budget
        if item.url.pathExtension.lowercased() != "m3u8" {
            if let seconds, let duration = item.durationHint, duration > 0 {
                let probe = try await fetch(item.url, item: item, start: 0, count: min(2, budget), prefetch: true)
                remaining -= probe.data.count
                let estimated = Int(Double(probe.total) * min(1, max(0, seconds) / duration))
                remaining = min(remaining, max(0, estimated - probe.data.count))
            }
            if remaining > 0 { _ = try await fetch(item.url, item: item, start: 0, count: remaining, prefetch: true) }
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
                let t = try await fetch(ref, item: item, start: 0, count: remaining, prefetch: true)
                remaining -= t.data.count
                if !line.hasPrefix("#") { elapsed += segmentDuration }
            }
        }
    }
    private func fetch(_ url: URL, item: HMMediaItem, start: Int, count: Int, prefetch: Bool) async throws -> Transfer {
        try Task.checkCancellation()
        guard count > 0, ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw URLError(.unsupportedURL) }
        let key = HMCacheKey.canonical(url)
        let owner = HMCacheKey.canonical(item.url)
        if configuration.strategy.usesDataCache, let total = await cache.total(for: key) {
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
        let mime = http.mimeType ?? (url.pathExtension == "m3u8" ? "application/vnd.apple.mpegurl" : "video/mp4")
        let data = result.data
        account(result.received, url: url, item: item, prefetch: prefetch)
        if prefetch, !data.isEmpty { prefetchRanges[key, default: []].append(HMByteRange(start: start, end: start + data.count - 1)) }
        else if !data.isEmpty { recordDelivery(key: key, item: item, start: start, count: data.count) }
        try Task.checkCancellation()
        if configuration.strategy.usesDataCache {
            await cache.put(key: key, start: start, data: data, total: total, mime: mime, base: http.url ?? url, owner: owner,
                            prefetched: prefetch, played: played.contains(item.id))
            cachedBytes[owner] = await cache.bytes(for: owner)
        }
        return Transfer(data: data, total: total, mime: mime, base: http.url ?? url, start: start)
    }
    private func recordDelivery(key: String, item: HMMediaItem, start: Int, count: Int) {
        let range = HMByteRange(start: start, end: start + count - 1)
        if played.contains(item.id) { playedRanges[key, default: []].append(range) }
        else { warmDeliveries[item.id, default: [:]][key, default: []].append(range) }
    }
    private func account(_ bytes: Int, url: URL, item: HMMediaItem, prefetch: Bool) {
        if prefetch { prefetchedNetwork[HMCacheKey.canonical(url), default: 0] += bytes }
        emit(.transfer, item: item, metrics: ["network_bytes": Double(bytes), "cache_bytes": 0, "prefetch_bytes": prefetch ? Double(bytes) : 0], properties: ["resource": HMCacheKey.hash(HMCacheKey.canonical(url))])
    }
    private func accept(_ connection: NWConnection) {
        guard !isFinishing else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { @MainActor in self?.close(id) } }
            if case .cancelled = state { Task { @MainActor in self?.close(id) } }
        }
        connection.start(queue: queue); receive(connection, id: id, accumulated: Data())
    }
    private func receive(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var buffer = accumulated; buffer.append(data ?? Data())
                if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let header = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                    self.responseTasks[id] = Task { [weak self] in await self?.serve(header, connection: connection, id: id) }
                } else if buffer.count > 16 * 1024 || complete || error != nil { self.close(id) }
                else { self.receive(connection, id: id, accumulated: buffer) }
            }
        }
    }
    private func serve(_ header: String, connection: NWConnection, id: UUID) async {
        let lines = header.components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ")
        guard request.count >= 2, request[0] == "GET" || request[0] == "HEAD" else { send(connection, id: id, code: 405, headers: [:], body: Data()); return }
        let token = request[1].split(separator: "/").first.map(String.init) ?? ""
        guard let route = routes[token] else { send(connection, id: id, code: 404, headers: [:], body: Data()); return }
        let rangeHeader = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }.map { $0.dropFirst(6).trimmingCharacters(in: .whitespaces) }
        do {
            if route.url.pathExtension == "m3u8" {
                let t = try await fetch(route.url, item: route.item, start: 0, count: 512 * 1024, prefetch: false)
                guard t.data.count == t.total, let text = String(data: t.data, encoding: .utf8) else { throw URLError(.badServerResponse) }
                let body = Data(HMPlaylist.rewrite(text, base: t.base) { proxyURL($0, item: route.item) }.utf8)
                send(connection, id: id, code: 200, headers: ["Content-Type": "application/vnd.apple.mpegurl", "Content-Length": String(body.count)], body: request[0] == "HEAD" ? Data() : body)
                return
            }
            let key = HMCacheKey.canonical(route.url)
            var total = configuration.strategy.usesDataCache ? await cache.total(for: key) : nil
            var initial: Transfer?
            if total == nil {
                // Discover size with a tiny range; do not download a whole file
                // to answer an AVFoundation probe.
                initial = try await fetch(route.url, item: route.item, start: 0, count: 2, prefetch: false)
                total = initial!.total
            }
            guard let total, let range = HMByteRange.parse(rangeHeader, total: total, limit: Int.max) else {
                send(connection, id: id, code: 416, headers: ["Content-Range": "bytes */\(total ?? 0)"], body: Data()); return
            }
            let mime = initial?.mime ?? "video/mp4"
            let h = ["Content-Type": mime, "Accept-Ranges": "bytes", "Content-Range": "bytes \(range.start)-\(range.end)/\(total)", "Content-Length": String(range.count), "Connection": "close", "Cache-Control": "no-store"]
            let head = "HTTP/1.1 206 Partial Content\r\n" + h.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n"
            try await sendBlock(connection, data: Data(head.utf8))
            if request[0] != "HEAD" {
                var cursor = range.start
                while cursor <= range.end {
                    try Task.checkCancellation()
                    let t: Transfer
                    if let initial, cursor == 0, range.count == initial.data.count { t = initial }
                    else { t = try await fetch(route.url, item: route.item, start: cursor, count: min(512 * 1024, range.end - cursor + 1), prefetch: false) }
                    guard !t.data.isEmpty else { throw URLError(.badServerResponse) }
                    try await sendBlock(connection, data: t.data)
                    cursor += t.data.count
                }
            }
            close(id)
        } catch {
            if !Task.isCancelled {
                // A client closing a completed AVFoundation probe is normal.
                if !(error is NWError) { emit(.transportError, item: route.item, properties: ["message": error.localizedDescription]) }
                close(id)
            }
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
        connection.send(content: packet, completion: .contentProcessed { [weak self] _ in Task { @MainActor in self?.close(id) } })
    }
    private func close(_ id: UUID) {
        responseTasks.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.cancel()
    }
    func finish() async -> Int {
        isFinishing = true
        listener.cancel()
        cancelPrefetch()
        let tasks = Array(responseTasks.values) + retiringPrefetch
        retiringPrefetch.removeAll()
        for id in Array(connections.keys) { close(id) }
        for task in tasks { await task.value }
        listener.cancel()
        // Speculative bytes are useful only where their byte ranges were
        // requested by an activated item's player (warm-only reads do not count).
        return prefetchedNetwork.reduce(0) { sum, pair in
            let used = HMRangeCoverage.overlap(prefetchRanges[pair.key] ?? [], playedRanges[pair.key] ?? [])
            return sum + max(0, pair.value - used)
        }
    }

    private func emit(_ kind: HMPlaybackEvent.Kind, item: HMMediaItem, metrics: [String: Double] = [:], properties: [String: String] = [:]) {
        onEvent?(HMPlaybackEvent(kind: kind, itemID: item.id, metrics: metrics, properties: properties), item)
    }
}
#endif
