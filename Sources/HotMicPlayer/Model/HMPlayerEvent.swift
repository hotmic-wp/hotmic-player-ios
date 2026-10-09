import Foundation

/// Readiness at activation, preserved through the first displayed frame.
public enum HMReadinessTier: String, Sendable {
    /// No reusable media bytes or decoded player.
    case cold
    /// URL and poster metadata resolved; no downloaded start or decoded player.
    case resolved
    /// Media bytes were cached, but the player was not ready to display.
    case cachedBytes
    /// A ready player with a decoded frame was reused.
    case warmPlayer
    static func atActivation(warm: Bool, cachedBytes: Int, minimumBytes: Int) -> Self {
        warm ? .warmPlayer : cachedBytes >= max(1, minimumBytes) ? .cachedBytes : .resolved
    }
}

/// Recoverable API and playback failures. Invalid playlist operations leave the playlist untouched.
public enum HMPlayerError: Error, Sendable, Equatable, LocalizedError {
    /// A playlist contains this ID more than once (or an empty ID).
    case duplicateID(String)
    /// A requested position is outside the playlist.
    case invalidIndex(Int)
    /// No resolver was supplied for an opaque reference.
    case missingResolver
    /// A resolver failed; the string describes the cause.
    case resolution(String)
    /// The decoder or transport failed.
    case playback(String)
    /// Paging failed.
    case playlistSource(String)
    /// Only file and HTTP(S) VOD URLs are supported.
    case unsupportedURL
    /// Seek time must be finite and nonnegative.
    case invalidSeek
    /// A human-readable description suitable for an error UI.
    public var errorDescription: String? {
        switch self {
        case .duplicateID(let id): return "Playlist IDs must be nonempty and unique: \(id)"
        case .invalidIndex(let index): return "Playlist index out of range: \(index)"
        case .missingResolver: return "A reference requires an HMItemResolver."
        case .resolution(let message), .playback(let message), .playlistSource(let message): return message
        case .unsupportedURL: return "Use a file or HTTP(S) VOD URL."
        case .invalidSeek: return "Seek time must be finite and nonnegative."
        }
    }
}

/// Ordered main-actor player notifications. Each `events` access creates an independent subscriber.
public enum HMPlayerEvent: Sendable, Equatable {
    /// Current entry changed, or became nil when the list emptied.
    case currentItemChanged(HMMediaItem?)
    /// The native player is ready for an entry.
    case itemReady(HMMediaItem)
    /// First displayed frame; TTFF is in seconds.
    case firstFrame(HMMediaItem, ttff: TimeInterval, readiness: HMReadinessTier)
    /// Current playback ran out of buffered media.
    case stallStarted(HMMediaItem)
    /// Playback recovered from a stall.
    case stallEnded(HMMediaItem)
    /// Recoverable failure; item is nil for a playlist-level error.
    case error(item: HMMediaItem?, kind: HMPlayerError)
    /// A successfully committed atomic playlist mutation.
    case playlistChanged([HMMediaItem])
    /// Non-fatal paging notice: these IDs were already loaded or repeated within the page. The cursor still advances.
    case sourcePageDuplicates(ids: [String])
    /// Current index entered the configured low-water region.
    case nearingEnd(remaining: Int)
}
