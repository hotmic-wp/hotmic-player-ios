#if canImport(AVFoundation) && !os(macOS)
import AVFoundation
import Foundation
import Observation

/// A fixed-size pool of recycled `HMPlayerNode`s.
///
/// Vertical feeds die from allocating an `AVPlayer` per cell. The pool caps the
/// number of live decoder sessions and hands the same handful of engines back
/// and forth as the viewer scrolls.
@MainActor
@Observable
final class HMPlayerPool {

    private(set) var nodes: [HMPlayerNode] = []
    private var assignments: [String: HMPlayerNode] = [:]  // itemID -> node
    @ObservationIgnored var configuration: HMPlayerConfiguration
    @ObservationIgnored var onEvent: ((HMPlaybackEvent, HMMediaItem) -> Void)?
    /// Called when a node is about to be reassigned, so analytics can detach.
    @ObservationIgnored var willRecycle: ((HMPlayerNode, HMMediaItem) -> Void)?

    init(configuration: HMPlayerConfiguration = .default) {
        self.configuration = configuration
        resize(to: configuration.poolSize)
    }

    /// Number of nodes currently holding content. Surfaced in the sample HUD.
    var busyCount: Int { nodes.filter { $0.item != nil }.count }

    func resize(to size: Int) {
        let target = max(1, min(4, size))
        if nodes.count < target {
            for index in nodes.count..<target {
                let node = HMPlayerNode(id: "hm-player-\(index)", configuration: configuration)
                node.onEvent = { [weak self] event, item in self?.onEvent?(event, item) }
                nodes.append(node)
            }
        } else if nodes.count > target {
            for node in nodes[target...] {
                if let item = node.item { assignments[item.id] = nil }
                node.release()
            }
            nodes.removeSubrange(target...)
        }
        applyConfiguration()
    }

    func applyConfiguration() {
        for node in nodes { node.configuration = configuration }
    }

    /// The node already responsible for `item`, if any. Does not allocate.
    func existingNode(for item: HMMediaItem) -> HMPlayerNode? {
        guard let node = assignments[item.id], node.item?.hasSameMedia(as: item, ignoring: configuration.volatileSigningQueryParameters) == true else { return nil }
        return node
    }

    /// Get a node for `item`, recycling the least-useful one if needed.
    ///
    /// - Parameter protectedItemIDs: items in the current prefetch window. These
    ///   are never evicted, which is what stops back-swipes from re-buffering.
    @discardableResult
    func node(for item: HMMediaItem, protecting protectedItemIDs: Set<String>, playbackURL: URL? = nil) -> HMPlayerNode {
        if let existing = existingNode(for: item) {
            existing.updateMetadata(item)
            existing.lastTouched = Date()
            return existing
        }

        let node = assignments[item.id] ?? evictionCandidate(protecting: protectedItemIDs)
        if let displaced = node.item {
            willRecycle?(node, item)
            assignments[displaced.id] = nil
        }
        assignments[item.id] = node
        node.lastTouched = Date()
        node.warm(with: item, playbackURL: playbackURL)
        return node
    }

    private func evictionCandidate(protecting protectedItemIDs: Set<String>) -> HMPlayerNode {
        // 1. A completely free node.
        if let free = nodes.first(where: { $0.item == nil }) { return free }
        // 2. The stalest node outside the protected window.
        let evictable = nodes
            .filter { node in node.item.map { !protectedItemIDs.contains($0.id) } ?? true }
            .sorted { $0.lastTouched < $1.lastTouched }
        if let candidate = evictable.first { return candidate }
        // 3. Pool is smaller than the window (misconfiguration): take the stalest.
        return nodes.min(by: { $0.lastTouched < $1.lastTouched }) ?? nodes[0]
    }

    /// Release every node not in `keepItemIDs`. Called after each page change.
    func trim(keeping keepItems: Set<HMMediaItem>) {
        for node in nodes {
            guard let item = node.item else { continue }
            if let updated = keepItems.first(where: { $0.hasSameMedia(as: item, ignoring: configuration.volatileSigningQueryParameters) }) {
                node.updateMetadata(updated); continue
            }
            willRecycle?(node, item)
            assignments[item.id] = nil
            node.release()
        }
    }

    func releaseAll() {
        for node in nodes {
            if let item = node.item { willRecycle?(node, item) }
            node.release()
        }
        assignments.removeAll()
    }
}
#endif
