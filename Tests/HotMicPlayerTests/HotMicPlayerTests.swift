import Testing
import Foundation
@testable import HotMicPlayer

@Suite("Prefetch policy")
struct PrefetchPolicyTests {

    @Test("Off produces no warm window")
    func offIsEmpty() {
        #expect(HMPrefetchPolicy.off.windowOffsets.isEmpty)
    }

    @Test("Nearest neighbours are warmed first")
    func interleavesNearestFirst() {
        // Order matters: whichever item is warmed first gets the bandwidth.
        #expect(HMPrefetchPolicy(ahead: 2, behind: 1).windowOffsets == [1, -1, 2])
        #expect(HMPrefetchPolicy.aggressive.windowOffsets == [1, -1, 2, -2, 3])
    }

    @Test("Asymmetric windows only extend on the requested side")
    func asymmetric() {
        #expect(HMPrefetchPolicy(ahead: 3, behind: 0).windowOffsets == [1, 2, 3])
        #expect(HMPrefetchPolicy(ahead: 0, behind: 2).windowOffsets == [-1, -2])
    }
}

@Suite("Playback snapshot")
struct PlaybackSnapshotTests {

    @Test("Progress is measured inside the seekable window")
    func progressUsesSeekableWindow() {
        var snapshot = HMPlaybackSnapshot()
        snapshot.currentTime = 25
        snapshot.duration = 50
        #expect(abs(snapshot.progress - 0.5) < 0.001)

        // A DVR window that has slid forward: 100...160, playhead at 130.
        snapshot.seekableStart = 100
        snapshot.duration = 160
        snapshot.currentTime = 130
        #expect(abs(snapshot.progress - 0.5) < 0.001)
        #expect(abs(snapshot.seekableDuration - 60) < 0.001)
    }

    @Test("Progress is clamped and safe when duration is unknown")
    func progressClamps() {
        var snapshot = HMPlaybackSnapshot()
        #expect(snapshot.progress == 0)

        snapshot.duration = 10
        snapshot.currentTime = 999
        #expect(snapshot.progress == 1)

        snapshot.currentTime = -5
        #expect(snapshot.progress == 0)
    }
}

@Suite("Mock timeline")
struct MockTimelineTests {

    @Test("Generation is deterministic for a given item id")
    @MainActor
    func deterministic() {
        let first = HMMockTimeline(itemID: "clip-a", duration: 30)
        let second = HMMockTimeline(itemID: "clip-a", duration: 30)
        #expect(first.events.map(\.id) == second.events.map(\.id))
        #expect(first.markers.map(\.offset) == second.markers.map(\.offset))
    }

    @Test("Different items generate different timelines")
    @MainActor
    func varies() {
        let a = HMMockTimeline(itemID: "clip-a", duration: 30)
        let b = HMMockTimeline(itemID: "clip-b", duration: 30)
        #expect(a.markers.map(\.offset) != b.markers.map(\.offset))
    }

    @Test("Windowed queries only return events inside the range")
    @MainActor
    func windowing() {
        let timeline = HMMockTimeline(itemID: "clip-a", duration: 100)
        let window = 20.0...40.0
        for event in timeline.events(in: window) {
            #expect(window.contains(event.offset))
        }
    }

    @Test("Markers are capped, spaced and ordered by time")
    @MainActor
    func markersAreDrawable() {
        let timeline = HMMockTimeline(itemID: "clip-a", duration: 100)
        #expect(timeline.markers.count <= 5)
        #expect(timeline.markers.map(\.offset) == timeline.markers.map(\.offset).sorted())
        for marker in timeline.markers {
            #expect(marker.position >= 0 && marker.position <= 1)
        }
        for (a, b) in zip(timeline.markers, timeline.markers.dropFirst()) {
            #expect(b.position - a.position >= 0.07, "markers would overlap on the rail")
        }
    }

    /// A marker over a flat stretch of the waveform reads as a bug, so they are
    /// taken from the same density array the bars are drawn from.
    @Test("Every marker sits on a visible peak")
    @MainActor
    func markersSitOnPeaks() {
        for id in ["clip-a", "clip-b", "clip-c", "clip-d"] {
            let timeline = HMMockTimeline(itemID: id, duration: 30)
            for marker in timeline.markers {
                let bucket = timeline.density.min {
                    abs($0.position - marker.position) < abs($1.position - marker.position)
                }
                #expect((bucket?.intensity ?? 0) >= 0.62, "marker on a flat bucket in \(id)")
            }
        }
    }

    /// The floating reactions are emitted in proportion to reaction weight in
    /// the window the playhead just crossed. If ambient chatter carries roughly
    /// as much weight as a peak, they stream constantly and look unrelated to
    /// the timeline — which is exactly how this regressed once before.
    @Test("Reactions surge at peaks instead of trickling uniformly")
    @MainActor
    func reactionsSurgeAtPeaks() {
        for id in ["clip-a", "clip-b", "clip-c"] {
            let duration = 20.0
            let timeline = HMMockTimeline(itemID: id, duration: duration)

            let perSecond = (0..<Int(duration)).map { second -> Double in
                timeline.events(in: Double(second)...Double(second + 1))
                    .filter { $0.kind == .reaction }
                    .reduce(0) { $0 + Double($1.magnitude) }
            }
            let sorted = perSecond.sorted()
            let median = sorted[sorted.count / 2]
            let peak = sorted.last ?? 0
            #expect(peak >= median * 6, "peak \(peak) vs median \(median) in \(id)")
        }
    }

    /// The overlay only flies emoji where the waveform is elevated, which is
    /// only meaningful if ambient chatter and peaks land on opposite sides of
    /// that threshold. Compressing the density differently would silently break
    /// the gate, so the separation is asserted here rather than in the app.
    /// A viewer's own reaction has to land on the timeline itself, not just
    /// animate — otherwise it vanishes the moment they scrub back over it.
    @Test("An appended reaction persists and moves the waveform")
    @MainActor
    func appendedReactionPersists() {
        let timeline = HMMockTimeline(itemID: "clip-a", duration: 20)
        let target = 6.0
        let bucket = { timeline.density.first { abs($0.position - target / 20) < 0.01 } }

        let before = bucket()?.intensity ?? 0
        let countBefore = timeline.events(in: 5.9...6.1).count

        for _ in 0..<12 {
            timeline.append(HMTimelineEvent(offset: target, kind: .reaction, emoji: "🔥", magnitude: 1))
        }

        #expect(timeline.events(in: 5.9...6.1).count == countBefore + 12)
        #expect((bucket()?.intensity ?? 0) > before, "waveform did not move")
        // Sorted order is what keeps `events(in:)`'s binary search valid.
        let offsets = timeline.events(in: 0...20).map(\.offset)
        #expect(offsets == offsets.sorted())
    }

    @Test("Density separates ambient chatter from peaks")
    @MainActor
    func densitySeparatesAmbientFromPeaks() {
        let overlayQuietFloor = 0.45
        for id in ["clip-a", "clip-b", "clip-c", "clip-d"] {
            let timeline = HMMockTimeline(itemID: id, duration: 20)
            let intensities = timeline.density.map(\.intensity).sorted()
            let median = intensities[intensities.count / 2]
            #expect(median < overlayQuietFloor - 0.1, "ambient too loud in \(id): \(median)")
            #expect((intensities.last ?? 0) > 0.9, "no clear peak in \(id)")
        }
    }

    /// Chat is the signal a human reads, so it must turn over slowly enough to
    /// follow even though reactions carry the engagement volume.
    @Test("Chat stays readable while reactions carry the volume")
    @MainActor
    func chatStaysReadable() {
        let timeline = HMMockTimeline(itemID: "clip-a", duration: 20)
        let chat = timeline.events(in: 0...20).filter { $0.kind == .chat }
        let reactions = timeline.events(in: 0...20).filter { $0.kind == .reaction }
        #expect(Double(chat.count) / 20 < 1.5, "chat rail would churn faster than it can be read")
        #expect(reactions.count > chat.count * 4)
    }

    @Test("Density covers the whole clip, not just its peaks")
    @MainActor
    func densitySpansTheClip() {
        // The failure this guards: a short clip rendering as an isolated burst
        // with a flat rail either side, which looks like the timeline does not
        // match the video.
        for duration in [9.0, 17.0, 42.0] {
            let timeline = HMMockTimeline(itemID: "clip-\(duration)", duration: duration)
            let populated = timeline.density.filter { $0.intensity > 0.15 }.count
            #expect(
                populated > timeline.density.count / 2,
                "only \(populated)/\(timeline.density.count) buckets visible at \(duration)s"
            )
        }
    }

    @Test("Density is normalised and covers the whole stream")
    @MainActor
    func densityIsNormalised() {
        let timeline = HMMockTimeline(itemID: "clip-a", duration: 100)
        #expect(timeline.density.count == 60)
        #expect(timeline.density.allSatisfy { $0.intensity >= 0 && $0.intensity <= 1 })
        // Normalisation means the busiest bucket must top out at exactly 1.
        #expect(timeline.density.contains { abs($0.intensity - 1) < 0.0001 })
    }
}

@Suite("Static feed data source")
struct FeedDataSourceTests {

    @Test("Pages are served in order and loop with unique ids")
    func paginationLoops() async throws {
        let items = (0..<3).map {
            HMMediaItem(id: "item-\($0)", url: URL(string: "https://example.com/\($0).m3u8")!)
        }
        let source = HMStaticFeedDataSource(
            items: items, pageSize: 3, loopsForever: true, simulatedLatency: .zero
        )

        let first = try await source.loadPage(cursor: nil)
        #expect(first.items.map(\.id) == ["item-0", "item-1", "item-2"])

        let second = try await source.loadPage(cursor: first.nextCursor)
        // Ids must stay unique across laps or SwiftUI identity and analytics
        // views both collapse.
        #expect(Set(second.items.map(\.id)).isDisjoint(with: Set(first.items.map(\.id))))
        #expect(second.items.first?.url == items.first?.url)
    }

    @Test("A finite source terminates instead of looping")
    func finiteSourceEnds() async throws {
        let items = [HMMediaItem(id: "only", url: URL(string: "https://example.com/a.m3u8")!)]
        let source = HMStaticFeedDataSource(
            items: items, pageSize: 1, loopsForever: false, simulatedLatency: .zero
        )
        let first = try await source.loadPage(cursor: nil)
        #expect(first.items.count == 1)
        let second = try await source.loadPage(cursor: first.nextCursor)
        #expect(second.items.isEmpty)
        #expect(second.nextCursor == nil)
    }
}

@Suite("Mux payload mapping")
struct MuxPayloadTests {

    @Test("Environment maps onto Mux's documented key names")
    func environmentPayload() {
        let environment = HMMuxEnvironment(
            environmentKey: "abc123",
            playerName: "HotMicVerticalFeed",
            viewerUserID: "viewer-1",
            customDimensions: ["surface": "feed"]
        )
        let payload = environment.payload
        #expect(payload["env_key"] == "abc123")
        #expect(payload["player_name"] == "HotMicVerticalFeed")
        #expect(payload["viewer_user_id"] == "viewer-1")
        #expect(payload["custom_1"] == "feed")
    }

    @Test("Live and on-demand map to Mux's stream types")
    func videoStreamType() {
        let url = URL(string: "https://stream.mux.com/abc.m3u8")!
        let vod = HMMediaItem(id: "v", url: url, title: "T", durationHint: 30)
        #expect(HMMuxVideoData(item: vod, duration: nil).payload["video_stream_type"] == "on-demand")

        let live = HMMediaItem(id: "l", url: url, streamKind: .live)
        #expect(HMMuxVideoData(item: live, duration: nil).payload["video_stream_type"] == "live")
    }

    @Test("Duration observed from the player wins over the feed's hint")
    func durationPrecedence() {
        let item = HMMediaItem(
            id: "v",
            url: URL(string: "https://stream.mux.com/abc.m3u8")!,
            durationHint: 30
        )
        // Mux expects milliseconds.
        #expect(HMMuxVideoData(item: item, duration: nil).payload["video_duration"] == "30000")
        #expect(HMMuxVideoData(item: item, duration: 42).payload["video_duration"] == "42000")
    }
}

@Suite("Page transitions")
struct PageTransitionTests {

    @Test("A centred page is never transformed")
    func centredIsIdentity() {
        for transition in HMPageTransition.allCases {
            let attributes = transition.attributes(offset: 0, height: 800)
            #expect(attributes.opacity == 1)
            #expect(attributes.scale == 1)
            #expect(attributes.offsetY == 0)
            #expect(attributes.rotationDegrees == 0)
        }
    }

    @Test("Off-screen pages stay within renderable bounds")
    func offsetsAreClamped() {
        for transition in HMPageTransition.allCases {
            let far = transition.attributes(offset: 9, height: 800)
            let near = transition.attributes(offset: 1.5, height: 800)
            #expect(far == near, "offset should clamp for \(transition.rawValue)")
            #expect(far.opacity >= 0 && far.opacity <= 1)
        }
    }
}

@Suite("Live window tracking")
struct LiveWindowTrackerTests {

    /// Replays what the Mux live test stream actually does: a 20s window that
    /// only advances when the manifest refreshes every 2s, and whose depth
    /// toggles by a segment as it is trimmed. Sampled at 10 Hz.
    private func simulate(
        ticks: Int = 200,
        smoothed: Bool
    ) -> (positions: [Double], behind: [Double]) {
        var tracker = HMLiveWindowTracker()
        var positions: [Double] = []
        var behind: [Double] = []

        for tick in 0...ticks {
            let now = Double(tick) / 10
            let step = (now / 2).rounded(.down) * 2
            let measuredEdge = 100 + step
            // Window is trimmed a segment late every other refresh.
            let depth: Double = Int(step / 2) % 2 == 0 ? 20 : 18
            let measuredStart = measuredEdge - depth
            // Playhead advances smoothly, sitting 5s behind the true edge.
            let currentTime = 95 + now

            let start: Double
            let edge: Double
            if smoothed {
                let window = tracker.update(
                    measuredStart: measuredStart, measuredEdge: measuredEdge, now: now
                )
                start = window.start
                edge = window.edge
            } else {
                start = measuredStart
                edge = measuredEdge
            }

            guard now > 3 else { continue }
            positions.append((currentTime - start) / (edge - start))
            behind.append(edge - currentTime)
        }
        return (positions, behind)
    }

    @Test("Raw manifest values are what make the playhead jitter")
    func rawIsUnstable() {
        // Guards the premise: if this ever stops being true the smoothing is
        // no longer earning its keep.
        let raw = simulate(smoothed: false).positions
        let spread = (raw.max() ?? 0) - (raw.min() ?? 0)
        #expect(spread > 0.1, "expected the unsmoothed signal to swing")
    }

    @Test("Smoothed position is steady while playing at 1x")
    func smoothedIsStable() {
        let positions = simulate(smoothed: true).positions
        let spread = (positions.max() ?? 0) - (positions.min() ?? 0)
        // Under 1% of the rail is a pixel or two — invisible.
        #expect(spread < 0.01, "playhead swung across \(spread * 100)% of the rail")
    }

    @Test("Position never slides backwards during steady playback")
    func positionIsMonotonic() {
        let positions = simulate(smoothed: true).positions
        for (previous, next) in zip(positions, positions.dropFirst()) {
            #expect(next >= previous - 0.002, "playhead moved backwards")
        }
    }

    @Test("The edge never runs far ahead of the manifest")
    func leadIsBounded() {
        var tracker = HMLiveWindowTracker()
        _ = tracker.update(measuredStart: 80, measuredEdge: 100, now: 0)
        // Manifest stops updating entirely; wall clock keeps going.
        let window = tracker.update(measuredStart: 80, measuredEdge: 100, now: 60)
        #expect(window.edge <= 100 + tracker.maximumLead)
    }

    @Test("A restarted stream resyncs instead of holding the old edge")
    func resyncsOnBackwardJump() {
        var tracker = HMLiveWindowTracker()
        _ = tracker.update(measuredStart: 480, measuredEdge: 500, now: 0)
        let window = tracker.update(measuredStart: 2, measuredEdge: 12, now: 0.1)
        #expect(window.edge == 12)
        #expect(window.start == 2)
    }
}
