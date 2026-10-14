import Foundation

/// Shared waveform construction. Rebuilt only on mutations, never on a playback tick.
struct HMTimelineAggregation {
    static func build(events: [HMTimelineEvent], duration: TimeInterval, bucketCount: Int) -> ([HMDensityBucket], [HMTimelineMarker]) {
        guard duration > 0, bucketCount > 0 else { return ([], []) }
        var weights = [Int](repeating: 0, count: bucketCount)
        var emojiTally = [[String: Int]](repeating: [:], count: bucketCount)
        for event in events where event.kind != .marker && event.offset.isFinite {
            let index = Int(min(Double(bucketCount - 1), max(0, event.offset / duration * Double(bucketCount))))
            weights[index] += event.magnitude
            if let emoji = event.emoji { emojiTally[index][emoji, default: 0] += event.magnitude }
        }
        return build(weights: weights, emojiTally: emojiTally, duration: duration)
    }

    static func build(weights: [Int], emojiTally: [[String: Int]], duration: TimeInterval) -> ([HMDensityBucket], [HMTimelineMarker]) {
        let count = weights.count
        // Smooth across neighbours so the rail reads as a waveform rather than
        // a picket fence of isolated spikes.
        let smoothed = (0..<count).map { index -> Double in
            let previous = Double(weights[max(0, index - 1)])
            let current = Double(weights[index])
            let next = Double(weights[min(count - 1, index + 1)])
            return (previous + current * 2 + next) / 4
        }

        let peak = max(1, smoothed.max() ?? 1)
        let density = (0..<count).map { index in
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
        return (density, Self.peakMarkers(in: density, duration: duration, limit: 5))
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
}
