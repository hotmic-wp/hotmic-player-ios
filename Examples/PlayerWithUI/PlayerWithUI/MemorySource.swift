import Foundation
import HotMicPlayer

/// A local source with no network or Benchmark SPI. Player-created engagements borrow it.
@MainActor final class MemorySource: HMInteractionSource {
    func timeline(for item: HMMediaItem) -> any HMStreamTimeline {
        MemoryTimeline(duration: item.durationHint ?? 10)
    }
    func capabilities(for item: HMMediaItem) -> HMEngagementCapabilities { .all }
    func polls(for item: HMMediaItem) -> [HMPoll] {
        [HMPoll(id: "favorite", question: "Ready to integrate?",
                options: [.init(id: "yes", text: "Let's go"), .init(id: "docs", text: "Reading the docs")], opensAt: 0)]
    }
    // Nil keeps the local event ID. HMEngagement appends each accepted event to its timeline.
    func sendChat(_ message: HMChatMessage, for item: HMMediaItem) async throws -> HMTimelineEvent? { nil }
    func react(_ reaction: HMTimelineEvent, for item: HMMediaItem) async throws -> HMTimelineEvent? { nil }
    func react(_ emoji: String, toMessage messageID: String, for item: HMMediaItem) async throws {}
    func vote(pollID: String, optionID: String, for item: HMMediaItem) async throws {}
}

@MainActor final class MemoryTimeline: HMStreamTimeline {
    let duration: TimeInterval
    private var history: [HMTimelineEvent] = [
        .init(id: "welcome", offset: 0, kind: .chat, author: "Host", text: "Try a reaction, vote, or comment.")
    ]
    init(duration: TimeInterval) { self.duration = duration }
    func events(in range: ClosedRange<TimeInterval>) -> [HMTimelineEvent] {
        history.filter { range.contains($0.offset) }
    }
    func append(_ event: HMTimelineEvent) {
        guard !history.contains(where: { $0.id == event.id }) else { return }
        history.append(event)
        history.sort { $0.offset < $1.offset }
    }
    // This tiny source omits waveform aggregates; production sources precompute them on mutation.
    var density: [HMDensityBucket] { [] }
    var markers: [HMTimelineMarker] { [] }
}
