import Foundation
import HotMicPlayer
import HotMicPlayerUI

/// The B/R demo content set: 14 B/R clips on the benchmark CDN, HotMic-made ad creatives and
/// seeded synthetic engagement, all read from `Content/` (`br-demo-feed.json` plus one
/// `br-comments-*.json` per clip). The files are generated with a fixed seed, so every run shows
/// the same clips, comments, counts and viewer walk.
enum BRDemoContent {
    static let catalog = BRDemoCatalog.bundled()
    /// The vertical feed, slot 1 first. Item IDs are the clip IDs.
    static var items: [HMMediaItem] { catalog.feed.map { $0.mediaItem() } }
    /// Home's "MLB Postseason" playlist, P1 to P3.
    static var playlistItems: [HMMediaItem] { catalog.playlist.clips.map { $0.mediaItem(section: .playlist) } }
    /// The horizontal player's items, H1 and H2.
    static var horizontalItems: [HMMediaItem] { catalog.horizontal.map { $0.mediaItem(section: .horizontal) } }
    /// Slot 8, the 16:9 clip in the vertical feed.
    static var landscapeID: String { catalog.feed.first { $0.key == "s08" }?.clipID ?? "" }
    /// Title, description, community, hashtags, share and view counts; the source fills Fire, comments and the audience.
    static func metadata(for item: HMMediaItem) -> HMSocialContent {
        guard let clip = catalog.clip(forItemID: item.id) else { return HMSocialContent(title: item.title ?? "") }
        return HMSocialContent(title: clip.title, description: clip.description, hashtags: clip.hashtags,
                               community: clip.community, shareCount: clip.counts.shares, viewCount: clip.counts.views)
    }
}

/// `br-demo-feed.json`.
struct BRDemoCatalog: Decodable, Sendable {
    enum Section: String, Sendable { case feed, playlist, horizontal }
    struct Playlist: Decodable, Sendable {
        let title: String
        let clips: [BRDemoClip]
    }
    let version: Int
    /// The generator's seed; each clip's comments file records its own derived seed.
    let seed: Int
    /// The horizontal player only shows the side-car on clips at least this long (B/R: 90 s).
    let horizontalSideCarMinimumDuration: Double
    let feed: [BRDemoClip]
    let playlist: Playlist
    let horizontal: [BRDemoClip]
    /// Keys: `sideCar16x9_30`, `sideCar16x9_15`, `preRoll16x9`, `preRoll9x16`.
    let ads: [String: BRDemoCreative]
    /// Sponsor banner for slot 7.
    let banner: URL

    func clip(forItemID id: String) -> BRDemoClip? { lookup(id)?.clip }
    func section(forItemID id: String) -> Section? { lookup(id)?.section }
    private func lookup(_ id: String) -> (clip: BRDemoClip, section: Section)? {
        if let clip = feed.first(where: { $0.itemID(in: .feed) == id }) { return (clip, .feed) }
        if let clip = playlist.clips.first(where: { $0.itemID(in: .playlist) == id }) { return (clip, .playlist) }
        if let clip = horizontal.first(where: { $0.itemID(in: .horizontal) == id }) { return (clip, .horizontal) }
        return nil
    }
    static func bundled(_ bundle: Bundle = .main) -> BRDemoCatalog {
        do { return try load(BRDemoCatalog.self, resource: "br-demo-feed.json", bundle: bundle) }
        catch { fatalError("BR demo content is missing or invalid: \(error)") }
    }
    static func load<Value: Decodable>(_ type: Value.Type, resource: String, bundle: Bundle = .main) throws -> Value {
        guard let url = bundle.url(forResource: resource, withExtension: nil) else { throw CocoaError(.fileNoSuchFile) }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}

/// One clip in the catalog. `key` is the demo-script slot (`s01`…`s10`, `p1`…`p3`, `h1`, `h2`).
struct BRDemoClip: Decodable, Sendable {
    struct Creator: Decodable, Sendable {
        let handle: String
        let name: String
        let avatarURL: URL?
    }
    struct Counts: Decodable, Sendable {
        let fire: Int
        let comments: Int
        let shares: Int
        let views: Int
    }
    let key: String
    let clipID: String
    /// Served-capped HLS: B/R's as-served ladder (the SDK applies its startup cap).
    let url: URL
    let format: String
    let poster: URL
    let width: Int
    let height: Int
    let aspect: Double
    let duration: Double
    let title: String
    let description: String
    let community: String
    let hashtags: [String]
    let creator: Creator
    let counts: Counts
    /// Whether comments and Fire counts rise as the crowd trickles in. Off where the script quotes exact counts.
    let liveCounts: Bool
    /// `preRoll16x9`, `preRoll9x16`, `sideCar` or `none`.
    let ad: String
    /// Sidecar WebVTT by language (slot 5). The other clips' as-served masters omit `CLOSED-CAPTIONS`, and the
    /// SDK no longer counts the undeclared CC option they imply, so those clips show no captions control.
    let captions: [String: URL]?
    let banner: URL?
    let shareURL: URL
    /// The clip's comments file in the bundle.
    let comments: String
    /// Overrides the horizontal side-car threshold (the H2 stand-in uses 30 s).
    let sideCarMinimumDuration: Double?

    func itemID(in section: BRDemoCatalog.Section) -> String {
        section == .feed ? clipID : "\(section.rawValue)-\(clipID)"
    }
    func mediaItem(section: BRDemoCatalog.Section = .feed) -> HMMediaItem {
        HMMediaItem(id: itemID(in: section), url: url, format: HMMediaItem.Format(rawValue: format) ?? .auto,
                    posterURL: poster, title: title, author: creator.handle, durationHint: duration,
                    metadata: ["br.slot": key, "br.ad": ad], aspectRatio: aspect, captionSources: captions ?? [:])
    }
}

/// A HotMic-made ad creative on the benchmark CDN.
struct BRDemoCreative: Decodable, Sendable, Equatable {
    let id: String
    let url: URL
    let poster: URL
    let duration: Double
    let aspect: Double

    func mediaItem() -> HMMediaItem {
        HMMediaItem(id: "br-ad-\(id)", url: url, format: .mp4, posterURL: poster, title: "Ad",
                    durationHint: duration, aspectRatio: aspect, presentation: .fit)
    }
}

/// One `br-comments-*.json`: the clip's comments, oldest first, and its viewer walk.
struct BRDemoComments: Decodable, Sendable {
    struct Row: Decodable, Sendable {
        let id: String
        let author: String
        let avatarURL: URL?
        let text: String
        let reactions: [String: Int]
        /// Media time for VOD replay.
        let offset: Double
        /// History rows: seconds before launch the comment was posted.
        let postedAgo: Double?
        /// Trickled rows: wall-clock seconds after the previous trickled comment.
        let gap: Double?
        /// Trickled rows: Fire taps that arrive with this comment.
        let fireBump: Int?

        func event(id: String? = nil, wallTime: Date?) -> HMTimelineEvent {
            HMTimelineEvent(id: id ?? self.id, offset: offset, kind: .chat, author: author, text: text,
                            avatarURL: avatarURL, wallTime: wallTime, reactions: reactions)
        }
    }
    struct Audience: Decodable, Sendable {
        let start: Int
        /// `[seconds until this value, viewers]`, looped.
        let ticks: [[Double]]
    }
    let key: String
    let clipID: String
    let seed: Int
    /// The first `historyCount` rows were posted before launch; the rest trickle in.
    let historyCount: Int
    let rows: [Row]
    let audience: Audience

    var history: ArraySlice<Row> { rows.prefix(historyCount) }
    var live: ArraySlice<Row> { rows.dropFirst(historyCount) }
}
