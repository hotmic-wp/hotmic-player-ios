import Observation

/// Player-owned, payload-free deletion records. Engagement eviction never forgets moderation.
@MainActor @Observable final class HMModerationState {
    // Bound both Set overhead and ID payload size per playlist item. Never discard an old
    // deletion to admit a new one: on overflow, hide the item's engagement until its lifetime ends.
    static let maximumIDs = 4_096
    static let maximumIDBytes = 256 * 1_024
    private(set) var revision = 0
    private(set) var eventRevision = 0
    @ObservationIgnored private(set) var eventIDs: Set<String> = []
    @ObservationIgnored private var pollIDs: Set<String> = []
    @ObservationIgnored private(set) var suppressesAll = false
    @ObservationIgnored private var idBytes = 0
    @ObservationIgnored private let idLimit: Int
    @ObservationIgnored private let byteLimit: Int

    init(idLimit: Int = HMModerationState.maximumIDs, byteLimit: Int = HMModerationState.maximumIDBytes) {
        self.idLimit = idLimit
        self.byteLimit = byteLimit
    }

    var hasEventRemovals: Bool { suppressesAll || !eventIDs.isEmpty }
    func removesEvent(_ id: String) -> Bool { suppressesAll || eventIDs.contains(id) }
    func removesPoll(_ id: String) -> Bool { suppressesAll || pollIDs.contains(id) }

    @discardableResult func removeEvent(_ id: String) -> Bool { record(id, isPoll: false) }
    @discardableResult func removePoll(_ id: String) -> Bool { record(id, isPoll: true) }

    private func record(_ id: String, isPoll: Bool) -> Bool {
        guard !suppressesAll, !(isPoll ? pollIDs.contains(id) : eventIDs.contains(id)) else { return false }
        let bytes = id.utf8.count
        if eventIDs.count + pollIDs.count >= idLimit || bytes > byteLimit - idBytes {
            suppressesAll = true
            eventIDs.removeAll(); pollIDs.removeAll(); idBytes = 0
            eventRevision += 1
        } else {
            if isPoll { pollIDs.insert(id) } else { eventIDs.insert(id); eventRevision += 1 }
            idBytes += bytes
        }
        revision += 1
        return true
    }
}
