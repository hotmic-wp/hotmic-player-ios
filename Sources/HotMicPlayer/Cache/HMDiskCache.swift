import Foundation

actor HMDiskCache {
    struct Entry: Codable {
        var key: String
        var start: Int
        var count: Int
        var total: Int
        var mime: String
        var base: URL
        var touched: Double
        var owner: String
        var prefetched: Int
        var played: Bool
        var filename: String { HMCacheKey.hash(key + ":" + String(start)) }
    }
    struct Hit { let data: Data; let total: Int; let mime: String; let base: URL }
    private let directory: URL
    private var entries: [String: Entry] = [:]
    private var capacity: Int
    private var pinned: Set<String> = []
    private(set) var wastedBytes = 0
    init(directory: URL, capacity: Int) {
        self.directory = directory; self.capacity = capacity
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved.filter { _, entry in
                let path = directory.appendingPathComponent(entry.filename).path
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                return (attrs?[.size] as? Int) == entry.count
            }
        }
        // Interrupted writes and obsolete schema files are not allowed to grow
        // outside the indexed LRU budget.
        let keep = Set(entries.values.map(\.filename)).union(["index.json"])
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where !keep.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
    func configure(capacity: Int, pinned: Set<String>) {
        self.capacity = max(0, capacity); self.pinned = pinned
        evict(); persist()
    }
    func markPlayed(_ owner: String) {
        for (k, var e) in entries where e.owner == owner { e.played = true; entries[k] = e }
        persist()
    }
    func bytes(for owner: String) -> Int {
        entries.values.filter { $0.owner == owner }.reduce(0) { $0 + $1.count }
    }
    func sizes() -> [String: Int] { Dictionary(grouping: entries.values, by: \.owner).mapValues { $0.reduce(0) { $0 + $1.count } } }
    func total(for key: String) -> Int? { entries.values.first { $0.key == key }?.total }
    func available(key: String, start: Int, count: Int) -> Hit? {
        guard let entry = entries.values.filter({ $0.key == key && $0.start <= start && $0.start + $0.count > start }).max(by: { $0.start + $0.count < $1.start + $1.count }) else { return nil }
        return read(key: key, range: HMByteRange(start: start, end: min(start + count - 1, entry.start + entry.count - 1)))
    }
    func read(key: String, range: HMByteRange) -> Hit? {
        guard let (k, entry) = entries.first(where: { $0.value.key == key && $0.value.start <= range.start && $0.value.start + $0.value.count > range.end }),
              let bytes = try? Data(contentsOf: directory.appendingPathComponent(entry.filename)),
              bytes.count == entry.count else { return nil }
        var e = entry; e.touched = Date().timeIntervalSince1970; entries[k] = e
        let offset = range.start - entry.start
        return Hit(data: bytes.subdata(in: offset..<(offset + range.count)), total: e.total, mime: e.mime, base: e.base)
    }
    func put(key: String, start: Int, data: Data, total: Int, mime: String, base: URL, owner: String, prefetched: Bool, played: Bool) {
        guard !Task.isCancelled, !data.isEmpty, data.count <= capacity else { return }
        let k = key + ":" + String(start)
        if let existing = entries[k], existing.count >= data.count { return }
        let e = Entry(key: key, start: start, count: data.count, total: total, mime: mime, base: base,
                      touched: Date().timeIntervalSince1970, owner: owner,
                      prefetched: prefetched ? data.count : 0, played: played)
        do {
            try data.write(to: directory.appendingPathComponent(e.filename), options: .atomic)
            entries[k] = e; evict(); persist()
        } catch { /* A full disk must not break playback. */ }
    }
    private func evict() {
        var size = entries.values.reduce(0) { $0 + $1.count }
        let sorted = entries.sorted {
            let lp = pinned.contains($0.value.owner), rp = pinned.contains($1.value.owner)
            return lp == rp ? $0.value.touched < $1.value.touched : !lp
        }
        for (k, e) in sorted where size > capacity {
            if !e.played { wastedBytes += e.prefetched }
            entries[k] = nil; size -= e.count
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(e.filename))
        }
    }
    func waste() -> Int { wastedBytes + entries.values.filter { !$0.played }.reduce(0) { $0 + $1.prefetched } }
    private func persist() {
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: directory.appendingPathComponent("index.json"), options: .atomic) }
    }
}
