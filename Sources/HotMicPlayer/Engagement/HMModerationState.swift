import Observation
import OSLog

/// Player-owned, bounded moderation records. Engagement eviction never forgets moderation.
@MainActor @Observable final class HMModerationState {
    // Bound both Set overhead and ID payload size per playlist item. Never discard an old
    // deletion to admit a new one: on overflow, hide the item's engagement until its lifetime ends.
    nonisolated static let maximumIDs = 4_096
    nonisolated static let maximumIDBytes = 256 * 1_024
    private static let logger = Logger(subsystem: "com.hotmic.player", category: "moderation")
    @ObservationIgnored private var observers: [WeakEngagement] = []
    @ObservationIgnored private(set) var reactionCounts: [String: [String: Int]] = [:]
    @ObservationIgnored private var reactionBytes = 0
    private let itemID: String
    private final class WeakEngagement {
        weak var value: HMEngagement?
        init(_ value: HMEngagement) { self.value = value }
    }
    func observe(_ engagement: HMEngagement) {
        observers.removeAll { $0.value == nil }
        observers.append(WeakEngagement(engagement))
    }
    private func notify(reactionsFor messageID: String? = nil) {
        observers.removeAll { $0.value == nil }
        for observer in observers { observer.value?.synchronizeModeration(reactionsFor: messageID) }
    }
    private(set) var revision = 0
    private(set) var eventRevision = 0
    @ObservationIgnored private(set) var eventIDs: Set<String> = []
    @ObservationIgnored private var pollIDs: Set<String> = []
    @ObservationIgnored private(set) var suppressesAll = false
    @ObservationIgnored private var idBytes = 0
    @ObservationIgnored private let idLimit: Int
    @ObservationIgnored private let byteLimit: Int

    init(itemID: String = "standalone", idLimit: Int = HMModerationState.maximumIDs, byteLimit: Int = HMModerationState.maximumIDBytes) {
        self.itemID = itemID
        self.idLimit = idLimit
        self.byteLimit = byteLimit
    }

    var hasEventRemovals: Bool { suppressesAll || !eventIDs.isEmpty }
    func removesEvent(_ id: String) -> Bool { suppressesAll || eventIDs.contains(id) }
    func removesPoll(_ id: String) -> Bool { suppressesAll || pollIDs.contains(id) }

    @discardableResult func removeEvent(_ id: String) -> Bool { record(id, isPoll: false) }
    @discardableResult func removePoll(_ id: String) -> Bool { record(id, isPoll: true) }

    // Authoritative totals are durable; deletion deltas remain engagement-local.
    func updateReactions(_ counts: [String: Int], for messageID: String) {
        guard !removesEvent(messageID) else { return }
        let counts = counts.mapValues { max(0, $0) }
        func size(_ values: [String: Int]) -> Int {
            messageID.utf8.count + values.reduce(0) { $0 + $1.key.utf8.count + MemoryLayout<Int>.size }
        }
        let oldBytes = reactionCounts[messageID].map(size) ?? 0
        let newBytes = size(counts)
        let newID = reactionCounts[messageID] == nil ? 1 : 0
        if eventIDs.count + pollIDs.count + reactionCounts.count + newID > idLimit ||
            newBytes > byteLimit - idBytes - reactionBytes + oldBytes {
            overflow()
        } else {
            reactionBytes += newBytes - oldBytes
            reactionCounts[messageID] = counts
        }
        revision += 1
        notify(reactionsFor: messageID)
    }

    private func overflow() {
        suppressesAll = true
        eventIDs.removeAll(); pollIDs.removeAll(); reactionCounts.removeAll()
        idBytes = 0; reactionBytes = 0; eventRevision += 1
        Self.logger.error("Moderation record overflow: engagement hidden for item \(self.itemID, privacy: .public); limits \(self.idLimit) IDs / \(self.byteLimit) bytes. Records reset when the item leaves the playlist.")
    }

    private func record(_ id: String, isPoll: Bool) -> Bool {
        guard !suppressesAll, !(isPoll ? pollIDs.contains(id) : eventIDs.contains(id)) else { return false }
        let bytes = id.utf8.count
        if eventIDs.count + pollIDs.count + reactionCounts.count >= idLimit || bytes > byteLimit - idBytes - reactionBytes {
            overflow()
        } else {
            if isPoll { pollIDs.insert(id) } else { eventIDs.insert(id); eventRevision += 1 }
            idBytes += bytes
        }
        revision += 1
        notify()
        return true
    }
}
