import Foundation

/// A single piece of playable content in a vertical feed.
///
/// `HMMediaItem` is intentionally transport-agnostic: it carries an HLS or
/// progressive URL plus the metadata analytics back ends (Mux, in particular)
/// need in order to attribute a view.
public struct HMMediaItem: Identifiable, Hashable, Sendable {

    public enum StreamKind: String, Sendable {
        case onDemand
        case live
    }

    /// Stable identifier. Also used as the analytics `video_id`.
    public let id: String
    /// Playback URL. HLS (`.m3u8`) is preferred; progressive MP4 works too.
    public let url: URL
    /// Optional still shown while the first frame is decoding.
    public let posterURL: URL?
    public let title: String?
    public let author: String?
    /// Known duration, if the feed API already told us. Avoids a metadata round trip.
    public let durationHint: TimeInterval?
    public let streamKind: StreamKind
    /// Free-form key/value pairs forwarded to analytics sinks as custom dimensions.
    public let metadata: [String: String]

    public init(
        id: String,
        url: URL,
        posterURL: URL? = nil,
        title: String? = nil,
        author: String? = nil,
        durationHint: TimeInterval? = nil,
        streamKind: StreamKind = .onDemand,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.url = url
        self.posterURL = posterURL
        self.title = title
        self.author = author
        self.durationHint = durationHint
        self.streamKind = streamKind
        self.metadata = metadata
    }
}
