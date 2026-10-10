import Foundation

/// An immutable VOD playlist entry. IDs are chosen by the app and must be unique in a playlist.
///
/// Use from any task; mutate only an exclusively owned value.
public struct HMMediaItem: Identifiable, Hashable, Sendable {
    /// The container type. Automatic detection uses the extension, then the origin's content type.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public enum Format: String, Sendable, Hashable, Codable {
        /// Detect MP4 or HLS from the URL or HTTP response.
        ///
        /// Use from any task; mutate only an exclusively owned value.
        case auto
        /// Progressive MP4.
        ///
        /// Use from any task; mutate only an exclusively owned value.
        case mp4
        /// On-demand HLS.
        ///
        /// Use from any task; mutate only an exclusively owned value.
        case hls
    }
    /// An opaque identifier understood by an item resolver, never a playback URL.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public struct Reference: Hashable, Sendable {
        /// Partner-defined namespace; the HotMicPlayerConnect adapter uses `hotmic`.
        ///
        /// Use from any task; mutate only an exclusively owned value.
        public let namespace: String
        /// Identifier in that namespace.
        ///
        /// Use from any task; mutate only an exclusively owned value.
        public let id: String
        /// Creates an opaque reference.
        ///
        /// Use from any task; mutate only an exclusively owned value.
        public init(namespace: String, id: String) { self.namespace = namespace; self.id = id }
    }
    /// A direct URL or an opaque reference resolved ahead of playback.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public enum Source: Hashable, Sendable {
        /// A file or HTTP(S) VOD URL, with an optional explicit format.
        ///
        /// Use from any task; mutate only an exclusively owned value.
        case url(URL, format: Format = .auto)
        /// An opaque reference requiring `HMItemResolver`.
        ///
        /// Use from any task; mutate only an exclusively owned value.
        case reference(namespace: String, id: String)
    }
    /// Stable app identity, also used as the analytics video ID.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let id: String
    /// Where to obtain this entry's VOD media.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let source: Source
    /// Optional still image displayed before decoding.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let posterURL: URL?
    /// Optional display title.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let title: String?
    /// Optional display author.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let author: String?
    /// Optional duration in seconds; the asset duration takes precedence.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let durationHint: TimeInterval?
    /// Optional display width / height, used until the decoded video size is known.
    public let aspectRatio: Double?
    /// Per-item rendering override; nil inherits the player's configuration.
    public let presentation: HMVideoPresentation?
    /// Sidecar WebVTT sources keyed by BCP-47 language (for example `en` or `es`).
    public let captionSources: [String: URL]
    /// App metadata forwarded to analytics.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public let metadata: [String: String]
    /// Direct URL, or nil for an unresolved reference.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public var url: URL? { if case let .url(url, _) = source { return url }; return nil }
    /// Requested format, with known extensions detected locally.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public var format: Format {
        guard case let .url(url, format) = source else { return .auto }
        if format != .auto { return format }
        switch url.pathExtension.lowercased() { case "m3u8": return .hls; case "mp4", "m4v": return .mp4; default: return .auto }
    }
    /// Creates a VOD entry with an explicit source and app-chosen ID.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public init(id: String, source: Source, posterURL: URL? = nil, title: String? = nil,
                author: String? = nil, durationHint: TimeInterval? = nil, metadata: [String: String] = [:]) {
        self.init(id: id, source: source, posterURL: posterURL, title: title, author: author,
                  durationHint: durationHint, metadata: metadata, aspectRatio: nil, presentation: nil)
    }
    /// Creates an entry with display metadata, retaining the original initializer function type.
    public init(id: String, source: Source, posterURL: URL?, title: String?, author: String?,
                durationHint: TimeInterval?, metadata: [String: String], aspectRatio: Double?, presentation: HMVideoPresentation?) {
        self.init(id: id, source: source, posterURL: posterURL, title: title, author: author,
                  durationHint: durationHint, metadata: metadata, aspectRatio: aspectRatio, presentation: presentation, captionSources: [:])
    }
    /// Creates a VOD entry with optional display metadata. Use from any task.
    public init(id: String, source: Source, posterURL: URL? = nil, title: String? = nil,
                author: String? = nil, durationHint: TimeInterval? = nil, metadata: [String: String] = [:],
                aspectRatio: Double? = nil, presentation: HMVideoPresentation? = nil, captionSources: [String: URL] = [:]) {
        self.id = id; self.source = source; self.posterURL = posterURL; self.title = title
        self.author = author; self.durationHint = durationHint; self.metadata = metadata
        self.aspectRatio = HMVideoAspect.valid(aspectRatio); self.presentation = presentation
        self.captionSources = captionSources
    }
    /// Creates a direct VOD entry.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public init(id: String, url: URL, format: Format = .auto, posterURL: URL? = nil, title: String? = nil,
                author: String? = nil, durationHint: TimeInterval? = nil, metadata: [String: String] = [:]) {
        self.init(id: id, url: url, format: format, posterURL: posterURL, title: title, author: author,
                  durationHint: durationHint, metadata: metadata, aspectRatio: nil, presentation: nil)
    }
    /// Creates a URL entry with display metadata, retaining the original initializer function type.
    public init(id: String, url: URL, format: Format, posterURL: URL?, title: String?, author: String?,
                durationHint: TimeInterval?, metadata: [String: String], aspectRatio: Double?, presentation: HMVideoPresentation?) {
        self.init(id: id, url: url, format: format, posterURL: posterURL, title: title, author: author,
                  durationHint: durationHint, metadata: metadata, aspectRatio: aspectRatio, presentation: presentation, captionSources: [:])
    }
    /// Creates a direct VOD entry with optional display metadata. Use from any task.
    public init(id: String, url: URL, format: Format = .auto, posterURL: URL? = nil, title: String? = nil,
                author: String? = nil, durationHint: TimeInterval? = nil, metadata: [String: String] = [:],
                aspectRatio: Double? = nil, presentation: HMVideoPresentation? = nil, captionSources: [String: URL] = [:]) {
        self.init(id: id, source: .url(url, format: format), posterURL: posterURL, title: title,
                  author: author, durationHint: durationHint, metadata: metadata, aspectRatio: aspectRatio, presentation: presentation, captionSources: captionSources)
    }
    /// Creates a URL entry. Supply an app ID when the same URL can occur twice; otherwise its absolute URL is the ID.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public static func url(_ url: URL, poster: URL? = nil, id: String? = nil, format: Format = .auto) -> Self {
        Self(id: id ?? url.absoluteString, url: url, format: format, posterURL: poster)
    }
    /// Creates a reference entry. The app ID defaults to the namespace and reference ID.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public static func reference(_ namespace: String, id: String, playlistID: String? = nil) -> Self {
        Self(id: playlistID ?? "\(namespace):\(id)", source: .reference(namespace: namespace, id: id))
    }
    /// Playback identity excludes display metadata so refreshes reuse decoders and bytes.
    struct MediaIdentity: Hashable { let id: String; let source: Source }
    var mediaIdentity: MediaIdentity { mediaIdentity(ignoring: []) }
    func mediaIdentity(ignoring parameters: [String]) -> MediaIdentity {
        let identitySource: Source
        if !parameters.isEmpty, case let .url(url, format) = source {
            identitySource = .url(URL(string: HMCacheKey.canonical(url, ignoring: parameters)) ?? url, format: format)
        } else { identitySource = source }
        return MediaIdentity(id: id, source: identitySource)
    }
    func hasSameMedia(as other: Self, ignoring parameters: [String] = []) -> Bool {
        mediaIdentity(ignoring: parameters) == other.mediaIdentity(ignoring: parameters)
    }
    func resolved(_ result: HMResolvedItem) -> Self {
        Self(id: id, url: result.url, format: result.format, posterURL: posterURL ?? result.poster,
             title: title ?? result.title, author: author, durationHint: durationHint ?? result.duration, metadata: metadata, aspectRatio: aspectRatio, presentation: presentation, captionSources: captionSources)
    }
    func identified(_ id: String) -> Self {
        Self(id: id, source: source, posterURL: posterURL, title: title, author: author, durationHint: durationHint, metadata: metadata, aspectRatio: aspectRatio, presentation: presentation, captionSources: captionSources)
    }
}
