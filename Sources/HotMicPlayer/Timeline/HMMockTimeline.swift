import Foundation

/// Deterministic fake engagement data.
///
/// MOCK — stands in for `HotMicSDK`'s live `StreamSession` callbacks and the
/// replay history fetch. Seeded from the item id so every run of the demo looks
/// identical, which matters when you are showing the same clip twice on stage.
@MainActor
@_spi(Benchmark) public final class HMMockTimeline: HMStreamTimeline {

    /// Media-clock duration in seconds.
    public let duration: TimeInterval
    /// Timeline events sorted by media offset.
    public private(set) var events: [HMTimelineEvent] = []
    /// Precomputed engagement density for the scrubber.
    public private(set) var density: [HMDensityBucket] = []
    /// Precomputed clustered peaks for the scrubber.
    public private(set) var markers: [HMTimelineMarker] = []

    private static let chatLines = [
        "this is unreal", "LETS GOOO", "no way he made that", "chat is cooked",
        "first time here, hooked already", "run it back", "that transition tho",
        "how is this live", "🔥 highlight of the week", "someone clip that",
        "my guy just cooked", "10/10 no notes", "wait rewind that",
        "the crowd went insane", "okay that was clean"
    ]
    private static let authors = [
        "mara_v", "dunkfiend", "chrisp", "lo-fi.jay", "nine_iron",
        "tinyhippo", "quietstorm", "reyna", "bags", "okaycool"
    ]
    private static let emojis = ["🔥", "😂", "😮", "💜", "👏", "🏆", "💀"]

    private static let bucketCount = 60

    private let itemID: String
    /// Raw per-bucket weight, kept so appending an event is a bucket update plus
    /// a 60-element rebuild rather than a rescan of the whole event list.
    private var weights = [Int](repeating: 0, count: HMMockTimeline.bucketCount)
    private var emojiTally = [[String: Int]](repeating: [:], count: HMMockTimeline.bucketCount)
    /// Monotonic counter behind every generated event id. Random UUIDs would
    /// break the determinism guarantee and make view identity unstable across
    /// a rebuild of the same timeline.
    private var nextEventNumber = 0

    /// Generates deterministic demo events from an item ID, duration and intensity.
    public init(itemID: String, duration: TimeInterval, intensity: Double = 1.0) {
        self.itemID = itemID
        self.duration = max(duration, 1)
        var rng = HMSeededGenerator(seed: HMMockTimeline.seed(from: itemID))
        generate(using: &rng, intensity: intensity)
    }

    private func eventID(_ number: Int) -> String { "\(itemID)-e\(number)" }

    /// Binary search, not a filter: this is called from overlay bodies on every
    /// playback tick, so it has to be O(log n + k) rather than O(n).
    public func events(in range: ClosedRange<TimeInterval>) -> [HMTimelineEvent] {
        guard !events.isEmpty else { return [] }
        let start = firstIndex(atOrAfter: range.lowerBound)
        var end = start
        while end < events.count, events[end].offset <= range.upperBound { end += 1 }
        return Array(events[start..<end])
    }

    private func firstIndex(atOrAfter offset: TimeInterval) -> Int {
        var low = 0
        var high = events.count
        while low < high {
            let mid = (low + high) / 2
            if events[mid].offset < offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    // MARK: - Generation

    private func generate(using rng: inout HMSeededGenerator, intensity: Double) {
        // Two or three "moments" where engagement spikes — this is what makes the
        // density ribbon and emoji markers legible instead of uniform noise.
        let peakCount = 2 + Int(rng.next(upTo: 2))
        let peaks: [(center: Double, emoji: String)] = (0..<peakCount).map { _ in
            (center: 0.15 + rng.nextDouble() * 0.7, emoji: Self.emojis[Int(rng.next(upTo: UInt64(Self.emojis.count)))])
        }

        // Ambient volume is tied to the bucket count, not the clip length. The
        // density array is a fixed 60 buckets wide, so scaling with duration
        // either leaves a short clip's rail empty or floods a long one.
        let ambientCount = Int(110 * intensity)
        var generated: [HMTimelineEvent] = []

        for _ in 0..<ambientCount {
            let position = rng.nextDouble()
            generated.append(makeChatOrReaction(at: position, peaks: peaks, rng: &rng))
        }

        for peak in peaks {
            // Roughly ten times the ambient rate once concentrated into the few
            // buckets a peak spans. That ratio is what makes reactions visibly
            // surge when the playhead reaches a marker.
            let burst = 80 + Int(rng.next(upTo: 30))
            for _ in 0..<burst {
                let jitter = (rng.nextDouble() - 0.5) * 0.09
                let position = min(0.99, max(0.01, peak.center + jitter))
                nextEventNumber += 1
                generated.append(
                    HMTimelineEvent(
                        id: eventID(nextEventNumber),
                        offset: position * duration,
                        kind: .reaction,
                        emoji: peak.emoji,
                        magnitude: 1 + Int(rng.next(upTo: 4))
                    )
                )
            }
            nextEventNumber += 1
            generated.append(
                HMTimelineEvent(
                    id: eventID(nextEventNumber),
                    offset: peak.center * duration,
                    kind: .marker,
                    text: "Crowd went off",
                    emoji: peak.emoji,
                    magnitude: burst
                )
            )
        }

        events = generated.sorted { $0.offset < $1.offset }
        for event in events { accumulate(event) }
        rebuildAggregates()
    }

    // MARK: - Appending

    /// Fold a new event in — a viewer's own reaction here, a socket message in
    /// production — keeping `events` sorted so the binary search stays valid.
    public func append(_ event: HMTimelineEvent) {
        let index = firstIndex(atOrAfter: event.offset)
        events.insert(event, at: index)
        accumulate(event)
        rebuildAggregates()
    }

    /// Share of ambient events that are chat rather than reactions.
    ///
    /// Low on purpose. Reactions carry the engagement volume the waveform is
    /// drawn from, but chat is the signal a human actually reads, so the rail
    /// has to turn over slowly enough to follow.
    private static let ambientChatShare = 0.13

    private func makeChatOrReaction(
        at position: Double,
        peaks: [(center: Double, emoji: String)],
        rng: inout HMSeededGenerator
    ) -> HMTimelineEvent {
        nextEventNumber += 1
        let isChat = rng.nextDouble() < Self.ambientChatShare
        if isChat {
            let id = eventID(nextEventNumber)
            return HMTimelineEvent(
                id: id,
                offset: position * duration,
                kind: .chat,
                author: Self.authors[Int(rng.next(upTo: UInt64(Self.authors.count)))],
                text: Self.chatLines[Int(rng.next(upTo: UInt64(Self.chatLines.count)))],
                wallTime: Self.recordedAt.addingTimeInterval(position * duration),
                reactions: Self.messageReactions(for: id)
            )
        }
        return HMTimelineEvent(
            id: eventID(nextEventNumber),
            offset: position * duration,
            kind: .reaction,
            emoji: Self.emojis[Int(rng.next(upTo: UInt64(Self.emojis.count)))],
            magnitude: 1 + Int(rng.next(upTo: 3))
        )
    }

    // MARK: - Aggregation
    //
    // Runs at construction and on append. Never on a per-frame path.

    private func bucketIndex(for offset: TimeInterval) -> Int {
        min(Self.bucketCount - 1, max(0, Int((offset / duration) * Double(Self.bucketCount))))
    }

    private func accumulate(_ event: HMTimelineEvent) {
        guard event.kind != .marker, duration > 0 else { return }
        let index = bucketIndex(for: event.offset)
        weights[index] += event.magnitude
        if let emoji = event.emoji {
            emojiTally[index][emoji, default: 0] += event.magnitude
        }
    }

    private func rebuildAggregates() {
        guard duration > 0 else { return }
        let count = Self.bucketCount

        // Smooth across neighbours so the rail reads as a waveform rather than
        // a picket fence of isolated spikes.
        let smoothed = (0..<count).map { index -> Double in
            let previous = Double(weights[max(0, index - 1)])
            let current = Double(weights[index])
            let next = Double(weights[min(count - 1, index + 1)])
            return (previous + current * 2 + next) / 4
        }

        let peak = max(1, smoothed.max() ?? 1)
        density = (0..<count).map { index in
            // Compressive rather than linear: normalising a spiky signal by its
            // maximum flattens ordinary chatter to nothing, which is what made
            // the timeline look like it only covered part of the clip.
            let normalised = pow(smoothed[index] / peak, 0.55)
            return HMDensityBucket(
                index: index,
                position: (Double(index) + 0.5) / Double(count),
                intensity: normalised,
                dominantEmoji: emojiTally[index].max(by: { $0.value < $1.value })?.key,
                eventCount: weights[index]
            )
        }
        markers = Self.peakMarkers(in: density, duration: duration, limit: 5)
    }

    /// Markers are derived from the rendered density, not from the raw events.
    ///
    /// Re-clustering the events independently lets a marker land somewhere the
    /// rail looks quiet, which reads as a bug. Picking local maxima out of the
    /// same array the bars are drawn from means a marker always sits on a peak
    /// you can see.
    static func peakMarkers(
        in density: [HMDensityBucket],
        duration: TimeInterval,
        limit: Int,
        threshold: Double = 0.62,
        minimumSeparation: Double = 0.07
    ) -> [HMTimelineMarker] {
        guard duration > 0 else { return [] }

        var chosen: [HMDensityBucket] = []
        for bucket in density.filter({ $0.intensity >= threshold && $0.dominantEmoji != nil })
            .sorted(by: { $0.intensity > $1.intensity }) {
            guard chosen.count < limit else { break }
            let crowded = chosen.contains { abs($0.position - bucket.position) < minimumSeparation }
            if !crowded { chosen.append(bucket) }
        }

        return chosen
            .sorted { $0.position < $1.position }
            .map { bucket in
                HMTimelineMarker(
                    id: "marker-\(bucket.index)",
                    offset: bucket.position * duration,
                    position: bucket.position,
                    emoji: bucket.dominantEmoji ?? "🔥",
                    count: bucket.eventCount
                )
            }
    }

    /// Fixed "recorded at" date so wall times are deterministic too.
    private static let recordedAt = Date(timeIntervalSince1970: 1_791_000_000)

    /// Reactions on a chat message. Hashed from the id rather than drawn from the
    /// generator, so adding them left every other event's position unchanged.
    private static func messageReactions(for id: String) -> [String: Int] {
        var rng = HMSeededGenerator(seed: seed(from: id + "#reactions"))
        guard rng.nextDouble() < 0.45 else { return [:] }
        var counts: [String: Int] = [:]
        counts[emojis[Int(rng.next(upTo: UInt64(emojis.count)))]] = 1 + Int(rng.next(upTo: 24))
        if rng.nextDouble() < 0.3 { counts[emojis[Int(rng.next(upTo: UInt64(emojis.count)))], default: 0] += 1 + Int(rng.next(upTo: 6)) }
        return counts
    }

    private static let pollTemplates: [(question: String, options: [String])] = [
        ("Rate that rep", ["🔥 Elite", "👍 Solid", "😬 Rough"]),
        ("Does he make the 53?", ["Lock", "Bubble", "Cut"]),
        ("Best play of the week?", ["Easily", "Not even close"]),
        ("Who wins this matchup?", ["Offense", "Defense"]),
        ("Run it back?", ["Again", "Next clip"])
    ]

    /// One deterministic poll per item, open from 20% to 70% of the clip.
    public static func polls(itemID: String, duration: TimeInterval) -> [HMPoll] {
        let duration = max(duration, 1)
        var rng = HMSeededGenerator(seed: seed(from: itemID + "#poll"))
        let template = pollTemplates[Int(rng.next(upTo: UInt64(pollTemplates.count)))]
        let options = template.options.enumerated().map { index, text in
            HMPoll.Option(id: "\(itemID)-poll-o\(index)", text: text, votes: 40 + Int(rng.next(upTo: 900)))
        }
        return [HMPoll(id: "\(itemID)-poll", question: template.question, options: options,
                       opensAt: duration * 0.2, closesAt: duration * 0.7)]
    }

    private static func seed(from string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash == 0 ? 0x9e3779b97f4a7c15 : hash
    }
}

/// Tiny SplitMix64. Keeps mock data identical across runs and platforms.
struct HMSeededGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }

    mutating func next(upTo bound: UInt64) -> UInt64 {
        bound == 0 ? 0 : next() % bound
    }

    mutating func nextDouble() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
