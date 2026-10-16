import Foundation
import HotMicPlayer

/// "Demo options → Fail this clip" (Squeezeback 1.1.22). Reloads the current clip, same ID, from a
/// URL that cannot load, so the kit's "Couldn't play this video · Tap to retry" status shows in
/// whatever size the video has. The retry is the player's own: the kit calls `jump(toID:)`, the
/// state leaves `.failed`, and that is the signal to put the real URL back, so the retry plays the
/// clip. Leaving the clip also restores it. Public player API only.
@MainActor final class BRClipFailureHook {
    private var brokenID: String?
    private var realItem: HMMediaItem?
    private var sawFailure = false

    func fail(_ player: HMPlayer) {
        restore(player)
        let items = player.items
        guard let current = player.currentItem, let url = current.url,
              let index = items.firstIndex(where: { $0.id == current.id }) else { return }
        // Same host and container, a playlist that does not exist: the CDN answers 403/404, a terminal failure.
        let missing = url.deletingLastPathComponent().appendingPathComponent("br-demo-unavailable.m3u8")
        let broken = HMMediaItem(id: current.id, source: .url(missing, format: current.format), posterURL: current.posterURL,
                                 title: current.title, author: current.author, durationHint: current.durationHint,
                                 metadata: current.metadata, aspectRatio: current.aspectRatio,
                                 presentation: current.presentation, captionSources: current.captionSources)
        var edited = items
        edited[index] = broken
        brokenID = current.id; realItem = current; sawFailure = false
        player.replaceAll(edited, startAt: index)
    }
    /// Call on every playback-state and current-item change.
    func observe(_ player: HMPlayer) {
        guard let brokenID else { return }
        guard player.currentItem?.id == brokenID else { restore(player); return }
        if player.snapshot.state == .failed { sawFailure = true }
        else if sawFailure { restore(player) }
    }
    /// Puts the real item back in place. Keeps the current selection; same ID and source preserve playback.
    func restore(_ player: HMPlayer) {
        guard let brokenID, let realItem else { forget(); return }
        forget()
        let items = player.items
        guard let index = items.firstIndex(where: { $0.id == brokenID }), items[index].url != realItem.url else { return }
        var edited = items
        edited[index] = realItem
        let selected = player.currentItem.flatMap { current in edited.firstIndex { $0.id == current.id } } ?? player.activeIndex
        player.replaceAll(edited, startAt: min(max(0, selected), edited.count - 1))
    }
    /// Drops the pending restore, for entries that replace the whole list anyway.
    func forget() { brokenID = nil; realItem = nil; sawFailure = false }
}
