import Foundation

/// Pure atomic playlist semantics, shared by the controller and focused tests.
struct HMPlaylistState: Equatable {
    var items: [HMMediaItem] = []
    var index = 0
    var current: HMMediaItem? { items.indices.contains(index) ? items[index] : nil }
    mutating func replaceAll(_ incoming: [HMMediaItem], startAt: Int) throws {
        try Self.validate(incoming)
        guard incoming.isEmpty ? startAt == 0 : incoming.indices.contains(startAt) else { throw HMPlayerError.invalidIndex(startAt) }
        items = incoming; index = startAt
    }
    mutating func replaceUpcoming(_ incoming: [HMMediaItem]) throws {
        let next = Array(items.prefix(items.isEmpty ? 0 : index + 1)) + incoming
        try Self.validate(next); items = next
    }
    mutating func insertNext(_ incoming: [HMMediaItem]) throws {
        let insertion = items.isEmpty ? 0 : index + 1
        var next = items; next.insert(contentsOf: incoming, at: insertion)
        try Self.validate(next); items = next
    }
    mutating func append(_ incoming: [HMMediaItem]) throws {
        let next = items + incoming; try Self.validate(next); items = next
    }
    mutating func remove(ids: Set<String>) {
        let old = current
        let successor = items.dropFirst(index + 1).first { !ids.contains($0.id) }
        let predecessor = items.prefix(index).last { !ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        let target = old.flatMap { ids.contains($0.id) ? nil : $0 } ?? successor ?? predecessor
        index = target.flatMap { item in items.firstIndex { $0.id == item.id } } ?? 0
    }
    func window(offsets: [Int]) -> [HMMediaItem] {
        var seen = Set<String>()
        return offsets.compactMap { offset in
            let position = index + offset
            guard items.indices.contains(position), seen.insert(items[position].id).inserted else { return nil }
            return items[position]
        }
    }
    func filterSourcePage(_ incoming: [HMMediaItem]) -> (items: [HMMediaItem], duplicates: [String]) {
        var seen = Set(items.map(\.id)), duplicates: [String] = []
        let unique = incoming.filter { item in
            if seen.insert(item.id).inserted { return true }
            duplicates.append(item.id); return false
        }
        return (unique, duplicates)
    }
    static func validate(_ items: [HMMediaItem]) throws {
        var ids = Set<String>()
        for item in items {
            guard !item.id.isEmpty, ids.insert(item.id).inserted else { throw HMPlayerError.duplicateID(item.id) }
            if let url = item.url, !["file", "http", "https"].contains(url.scheme?.lowercased() ?? "") { throw HMPlayerError.unsupportedURL }
        }
    }
}

/// A scroll move remains valid while both endpoint IDs occupy the same positions.
enum HMPagePosition {
    static func survives(old: [String], new: [String], current: String?, destination: String?) -> Bool {
        [current, destination].compactMap { $0 }.allSatisfy { id in
            guard let position = old.firstIndex(of: id) else { return false }
            return new.firstIndex(of: id) == position
        }
    }
}

/// Three automatic attempts, with capped exponential backoff; activation resets the budget.
struct HMResolutionRetry {
    static let maximumAttempts = 3
    var attempts = 0
    var nextAttempt: TimeInterval = 0
    mutating func failed(at now: TimeInterval) {
        attempts += 1
        nextAttempt = now + min(4, pow(2, Double(attempts - 1)))
    }
    func canRetry(at now: TimeInterval) -> Bool { attempts < Self.maximumAttempts && now >= nextAttempt }
}

/// Four total attempts, with 1/2/4-second waits. Navigation or explicit loading resets the budget.
struct HMPagingRetry {
    static let maximumAttempts = 4
    var attempts = 0
    var nextAttempt: TimeInterval = 0
    var exhausted: Bool { attempts >= Self.maximumAttempts }
    mutating func failed(at now: TimeInterval) {
        attempts += 1
        nextAttempt = now + min(4, pow(2, Double(attempts - 1)))
    }
    func canRetry(at now: TimeInterval) -> Bool { !exhausted && now >= nextAttempt }
}
