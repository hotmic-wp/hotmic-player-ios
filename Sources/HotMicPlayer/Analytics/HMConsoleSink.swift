import Foundation
import Observation
import OSLog

/// In-memory ring buffer of events. Drives the live event console in the sample
/// app and is genuinely useful in development builds.
///
/// Access on the main actor.
@MainActor
@Observable
public final class HMConsoleSink: HMAnalyticsSink {

    /// A captured console event and its display metadata.
    ///
    /// Use from any task; mutate only an exclusively owned value.
    public struct Entry: Identifiable, Sendable {
        /// Stable identity for this value.
        ///
        /// Use from any task; mutate only an exclusively owned value.
        public let id: UUID
        /// Original playback telemetry.
        ///
        /// Use from any task; mutate only an exclusively owned value.
        public let event: HMPlaybackEvent
        /// Display title captured when the event arrived.
        ///
        /// Use from any task; mutate only an exclusively owned value.
        public let itemTitle: String
        /// Event category.
        ///
        /// Use from any task; mutate only an exclusively owned value.
        public var kind: HMPlaybackEvent.Kind { event.kind }
        /// Wall-clock occurrence time.
        ///
        /// Use from any task; mutate only an exclusively owned value.
        public var timestamp: Date { event.timestamp }
    }

    /// Stable sink identifier used by the hub for deduplication.
    ///
    /// Access on the main actor.
    public let sinkName = "console"
    /// Recent events, newest first, bounded by the configured capacity.
    ///
    /// Access on the main actor.
    public private(set) var entries: [Entry] = []

    private let capacity: Int
    private let logger = Logger(subsystem: "com.hotmic.player", category: "playback")
    private let mirrorsToOSLog: Bool

    /// Creates a bounded console, optionally mirroring events to OSLog.
    ///
    /// Access on the main actor.
    public init(capacity: Int = 250, mirrorsToOSLog: Bool = true) {
        self.capacity = capacity
        self.mirrorsToOSLog = mirrorsToOSLog
    }

    /// Consumes one telemetry event on the main actor.
    ///
    /// Access on the main actor.
    public func handle(_ event: HMPlaybackEvent, item: HMMediaItem) {
        if mirrorsToOSLog {
            logger.debug("\(event.description, privacy: .public)")
        }
        entries.insert(Entry(id: event.id, event: event, itemTitle: item.title ?? item.id), at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
    }

    /// Clears the console ring buffer.
    ///
    /// Access on the main actor.
    public func clear() { entries.removeAll() }
}
