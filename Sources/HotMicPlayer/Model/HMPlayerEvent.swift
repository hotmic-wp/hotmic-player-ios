import Foundation

/// Readiness of an inactive prepared entry, or the measurement at activation for current playback.
///
/// Use from any task; mutate only an exclusively owned value.
public enum HMReadinessTier: String, Sendable {
    /// Current entry is awaiting URL or format resolution.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case resolving
    /// No reusable media bytes or decoded player.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case cold
    /// URL and poster metadata resolved; no downloaded start or decoded player.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case resolved
    /// Media bytes were cached, but the player was not ready to display.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case cachedBytes
    /// An inactive prepared player has a decoded frame, or a ready player was reused at activation.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case warmPlayer
    static func atActivation(warm: Bool, cachedBytes: Int, minimumBytes: Int) -> Self {
        warm ? .warmPlayer : cachedBytes >= max(1, minimumBytes) ? .cachedBytes : .resolved
    }
}

/// Recoverable API and playback failures. Invalid playlist operations leave the playlist untouched.
///
/// Use from any task; mutate only an exclusively owned value.
public enum HMPlayerError: Error, Sendable, Equatable, LocalizedError {
    /// A playlist contains this ID more than once (or an empty ID).
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case duplicateID(String)
    /// A requested position is outside the playlist.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case invalidIndex(Int)
    /// No resolver was supplied for an opaque reference.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case missingResolver
    /// A resolver failed; the string describes the cause.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case resolution(String)
    /// The decoder or transport failed.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case playback(String)
    /// Paging failed.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case playlistSource(String)
    /// Only file and HTTP(S) VOD URLs are supported.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case unsupportedURL
    /// Seek time must be finite and nonnegative.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case invalidSeek
    /// A human-readable description suitable for an error UI.
    ///
    /// Use from any task; mutate only an exclusively owned value.
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
///
/// Use from any task; mutate only an exclusively owned value.
public enum HMPlayerEvent: Sendable, Equatable {
    /// State/progress for the associated content visit, never an ad playlist entry.
    case adStateChanged(item: HMMediaItem, state: HMAdState)
    /// Exactly one outcome per consulted visit; cancellation includes swipe-away/teardown.
    case adBreakEnded(item: HMMediaItem, outcome: HMAdOutcome)
    /// Bulk work paused/resumed; current preroll and next content head remain protected.
    case adPrefetchChanged(paused: Bool)

    /// Audio or application lifecycle notification, delivered even when the host manages the session.
    case audioSession(HMAudioSessionEvent)
    /// Caption preference or available language selection changed.
    case captionsChanged(enabled: Bool, language: String?)

    /// Current entry changed, or became nil when the list emptied.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case currentItemChanged(HMMediaItem?)
    /// The native player is ready for an entry.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case itemReady(HMMediaItem)
    /// First displayed frame; TTFF is in seconds.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case firstFrame(HMMediaItem, ttff: TimeInterval, readiness: HMReadinessTier)
    /// Current playback ran out of buffered media.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case stallStarted(HMMediaItem)
    /// Playback recovered from a stall.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case stallEnded(HMMediaItem)
    /// Recoverable failure; item is nil for a playlist-level error.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case error(item: HMMediaItem?, kind: HMPlayerError)
    /// A successfully committed atomic playlist mutation.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case playlistChanged([HMMediaItem])
    /// Non-fatal paging notice: these IDs were already loaded or repeated within the page. The cursor still advances.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case sourcePageDuplicates(ids: [String])
    /// Current index entered the configured low-water region.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    case nearingEnd(remaining: Int)
    /// Picture in Picture or external playback started or stopped.
    case externalPresentationChanged(pictureInPicture: Bool, externalPlayback: Bool)
    /// Companion lifecycle. `item` is the item whose decision armed it, not necessarily the one on screen.
    case companionStateChanged(item: HMMediaItem, state: HMCompanionState)
    /// Exactly once per armed companion. Cancellation includes host dismissal, a later pre-roll and teardown.
    case companionEnded(item: HMMediaItem, outcome: HMAdOutcome)
}

/// Main-actor observations forwarded through `HMPlayer.events`.
public enum HMAudioSessionEvent: Sendable, Equatable {
    /// Playback was suspended by an audio interruption.
    case interruptionBegan
    /// The interruption ended; resumed reports whether automatic playback was requested.
    case interruptionEnded(shouldResume: Bool, resumed: Bool)
    /// The output route changed; reason is the AVAudioSession raw reason value.
    case routeChanged(reason: UInt)
    /// The application entered the background.
    case enteredBackground
    /// The application became active; resumed reports whether automatic playback was requested.
    case enteredForeground(resumed: Bool)
    /// Native playback objects and the managed session were rebuilt after a media services reset.
    case mediaServicesReset
}
