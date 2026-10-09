import Foundation

/// An immutable VOD playlist entry. IDs are chosen by the app and must be unique in a playlist.
public struct HMMediaItem: Identifiable, Hashable, Sendable {
    /// The container type. Automatic detection uses the extension, then the origin's content type.
    public enum Format: String, Sendable, Hashable, Codable {
        /// Detect MP4 or HLS from the URL or HTTP response.
        case auto
        /// Progressive MP4.
        case mp4
        /// On-demand HLS.
        case hls
    }
    /// An opaque identifier understood by an item resolver, never a playback URL.
    public struct Reference: Hashable, Sendable {
        /// Partner-defined namespace; the future Core adapter uses `hotmic`.
        public let namespace: String
        /// Identifier in that namespace.
        public let id: String
        /// Creates an opaque reference.
        public init(namespace: String, id: String) { self.namespace = namespace; self.id = id }
    }
    /// A direct URL or an opaque reference resolved ahead of playback.
    public enum Source: Hashable, Sendable {
        /// A file or HTTP(S) VOD URL, with an optional explicit format.
        case url(URL, format: Format = .auto)
        /// An opaque reference requiring `HMItemResolver`.
        case reference(namespace: String, id: String)
    }
    /// Stable app identity, also used as the analytics video ID.
    public let id: String
    /// Where to obtain this entry's VOD media.
    public let source: Source
    /// Optional still image displayed before decoding.
    public let posterURL: URL?
    /// Optional display title.
    public let title: String?
    /// Optional display author.
    public let author: String?
    /// Optional duration in seconds; the asset duration takes precedence.
    public let durationHint: TimeInterval?
    /// App metadata forwarded to analytics.
    public let metadata: [String: String]
    /// Direct URL, or nil for an unresolved reference.
    public var url: URL? { if case let .url(url, _) = source { return url }; return nil }
    /// Requested format, with known extensions detected locally.
    public var format: Format {
        guard case let .url(url, format) = source else { return .auto }
        if format != .auto { return format }
        switch url.pathExtension.lowercased() { case "m3u8": return .hls; case "mp4", "m4v": return .mp4; default: return .auto }
    }
    /// Creates a VOD entry with an explicit source and app-chosen ID.
    public init(id: String, source: Source, posterURL: URL? = nil, title: String? = nil,
                author: String? = nil, durationHint: TimeInterval? = nil, metadata: [String: String] = [:]) {
        self.id = id; self.source = source; self.posterURL = posterURL; self.title = title
        self.author = author; self.durationHint = durationHint; self.metadata = metadata
    }
    /// Creates a direct VOD entry.
    public init(id: String, url: URL, format: Format = .auto, posterURL: URL? = nil, title: String? = nil,
                author: String? = nil, durationHint: TimeInterval? = nil, metadata: [String: String] = [:]) {
        self.init(id: id, source: .url(url, format: format), posterURL: posterURL, title: title,
                  author: author, durationHint: durationHint, metadata: metadata)
    }
    /// Creates a URL entry. Supply an app ID when the same URL can occur twice; otherwise its absolute URL is the ID.
    public static func url(_ url: URL, poster: URL? = nil, id: String? = nil, format: Format = .auto) -> Self {
        Self(id: id ?? url.absoluteString, url: url, format: format, posterURL: poster)
    }
    /// Creates a reference entry. The app ID defaults to the namespace and reference ID.
    public static func reference(_ namespace: String, id: String, playlistID: String? = nil) -> Self {
        Self(id: playlistID ?? "\(namespace):\(id)", source: .reference(namespace: namespace, id: id))
    }
    func resolved(_ result: HMResolvedItem) -> Self {
        Self(id: id, url: result.url, format: result.format, posterURL: posterURL ?? result.poster,
             title: title ?? result.title, author: author, durationHint: durationHint ?? result.duration, metadata: metadata)
    }
    func identified(_ id: String) -> Self {
        Self(id: id, source: source, posterURL: posterURL, title: title, author: author, durationHint: durationHint, metadata: metadata)
    }
}
