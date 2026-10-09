import Foundation

/// Summary of one effective playlist edit. No-ops and rejected edits leave the previous summary intact.
/// IDs follow new playlist order for insertions/moves and old order for removals/releases.
/// A move means a surviving ID changed its absolute index (including shifts caused by insertion/removal).
/// Metadata-only edits produce empty ID lists and `currentChanged == false`.
/// Use from any task; this immutable value is Sendable and Equatable.
public struct HMPlaylistChange: Sendable, Equatable {
    /// IDs newly present in the playlist.
    public let insertedIDs: [String]
    /// IDs no longer present. Deferred removal appears only when the current entry leaves.
    public let removedIDs: [String]
    /// Surviving IDs whose absolute playlist index changed.
    public let movedIDs: [String]
    /// Whether current ID or media source changed; display metadata alone does not count.
    public let currentChanged: Bool
    /// Item IDs whose assigned native players were released or reassigned during this edit.
    public let releasedItemIDs: [String]
    /// Number of released assignments, not the number of pool slots allocated.
    public var releasedPlayerCount: Int { releasedItemIDs.count }

    init(old: [HMMediaItem], new: [HMMediaItem], currentChanged: Bool, releasedItemIDs: [String]) {
        let before = Dictionary(uniqueKeysWithValues: old.enumerated().map { ($1.id, $0) })
        let after = Dictionary(uniqueKeysWithValues: new.enumerated().map { ($1.id, $0) })
        insertedIDs = new.map(\.id).filter { before[$0] == nil }
        removedIDs = old.map(\.id).filter { after[$0] == nil }
        movedIDs = new.map(\.id).filter { before[$0] != nil && before[$0] != after[$0] }
        self.currentChanged = currentChanged; self.releasedItemIDs = releasedItemIDs
    }
}
