import Foundation
import Observation
import OSLog

/// In-memory ring buffer of events. Drives the live event console in the sample
/// app and is genuinely useful in development builds.
@MainActor
@Observable
public final class HMConsoleSink: HMAnalyticsSink {

    public struct Entry: Identifiable, Sendable {
        public let id: UUID
        public let event: HMPlaybackEvent
        public let itemTitle: String
        public var kind: HMPlaybackEvent.Kind { event.kind }
        public var timestamp: Date { event.timestamp }
    }

    public let sinkName = "console"
    public private(set) var entries: [Entry] = []

    private let capacity: Int
    private let logger = Logger(subsystem: "com.hotmic.player", category: "playback")
    private let mirrorsToOSLog: Bool

    public init(capacity: Int = 250, mirrorsToOSLog: Bool = true) {
        self.capacity = capacity
        self.mirrorsToOSLog = mirrorsToOSLog
    }

    public func handle(_ event: HMPlaybackEvent, item: HMMediaItem) {
        if mirrorsToOSLog {
            logger.debug("\(event.description, privacy: .public)")
        }
        entries.insert(Entry(id: event.id, event: event, itemTitle: item.title ?? item.id), at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
    }

    public func clear() { entries.removeAll() }
}
