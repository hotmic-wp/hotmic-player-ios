import Foundation
import HotMicPlayer

/// Home's ways into the player (demo script 6.3 and 6.4). Every entry reuses the same `HMPlayer`,
/// `HMSocialPlayerView` and options; only the starting clip and the list around it change.
enum BRDemoEntry: Equatable {
    /// "MLB Postseason": P1 to P3 in playlist order, then the general feed from clip 1.
    case playlist
    /// Clip 7's card: the general feed, positioned on clip 7.
    case clipCard
    /// A shared clip link: that clip first, then the general feed without it.
    case shareLink(URL)
    /// A push alert for clip 7: clip 7 first, then the general feed without it.
    case alert
}

extension BRDemoContent {
    /// Slot 7, the clip Home opens from its card, its share link and the alert.
    static var entryClip: BRDemoClip? { catalog.feed.first { $0.key == "s07" } }
    /// A demo-only share link for a feed clip. The scheme is not registered: Home simulates the open.
    static func shareLink(for clip: BRDemoClip) -> URL {
        URL(string: "brdemo://clip/\(clip.clipID)") ?? clip.shareURL
    }
    /// The feed item a share link points at.
    static func itemID(forShareLink url: URL) -> String? {
        let id = url.lastPathComponent
        return catalog.feed.contains { $0.clipID == id } ? id : nil
    }
}

extension BRFeedModel {
    func open(_ entry: BRDemoEntry) {
        let feed = BRDemoContent.items
        let clipID = BRDemoContent.entryClip?.clipID ?? ""
        switch entry {
        case .playlist:
            // Playlist items carry no ads in the catalog (B/R: a second playlist is not eligible).
            player.replaceAll(BRDemoContent.playlistItems + feed)
        case .clipCard:
            player.replaceAll(feed, startAt: feed.firstIndex { $0.id == clipID } ?? 0)
        case .shareLink(let url):
            lead(with: BRDemoContent.itemID(forShareLink: url) ?? clipID, feed: feed)
        case .alert:
            lead(with: clipID, feed: feed)
        }
        Task { await loadHistory() }
    }
    private func lead(with id: String, feed: [HMMediaItem]) {
        guard let first = feed.first(where: { $0.id == id }) else { player.replaceAll(feed); return }
        player.replaceAll([first] + feed.filter { $0.id != id })
    }
    /// Loads the first comment page for items that have none yet (the playlist, on its first visit).
    private func loadHistory() async {
        do {
            for item in player.items where data(item).content.comments.isEmpty && data(item).canLoadMore {
                try await data(item).loadMoreComments()
            }
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}
