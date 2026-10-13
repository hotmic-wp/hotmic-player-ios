import Testing
import Foundation
@_spi(Benchmark) @testable import HotMicPlayer

@Suite("Prefetch policy")
struct PrefetchPolicyTests {

    @Test("Nearest neighbours are warmed first")
    func interleavesNearestFirst() {
        // Order matters: whichever item is warmed first gets the bandwidth.
        #expect(HMPrefetchPolicy(ahead: 2, behind: 1).windowOffsets == [1, -1, 2])
        #expect(HMPrefetchPolicy.aggressive.windowOffsets == [1, -1, 2, -2, 3])
        // Asymmetric cases share the same distance-order contract.
        #expect(HMPrefetchPolicy(ahead: 3, behind: 0).windowOffsets == [1, 2, 3])
        #expect(HMPrefetchPolicy(ahead: 0, behind: 2).windowOffsets == [-1, -2])
        #expect(HMPrefetchPolicy.off.windowOffsets.isEmpty)
        #expect(HMPrefetchPolicy(ahead: -1, behind: -2).windowOffsets.isEmpty)
        for config in [HMPlayerConfiguration.default, HMPlayerConfiguration()] {
            #expect(config.poolSize == 2 && !config.adaptive && config.activationTrigger == .lift)
            #expect(config.prefetch.ahead == 3 && config.prefetch.behind == 1)
            #expect(config.prefetch.secondsPerItem == 4 && config.prefetch.bytesPerItem == 8 * 1024 * 1024)
            #expect(config.startupPeakBitRate == 1_600_000 && config.startupBitRateWindow == 4)
        }
        #expect(HMPlayerConfiguration(prefetch: .off).warmOffsets.isEmpty)
        #expect(HMPrefetchPolicy.off.bytesPerItem == 0 && HMPrefetchPolicy.off.secondsPerItem == 0)
        #expect(HMPlayerConfiguration.default.warmOffsets == [1])
        var three = HMPlayerConfiguration.default; three.poolSize = 3
        #expect(three.warmOffsets == [1, -1])
        #expect(HMPlayerConfiguration.preset(.S0).warmOffsets.isEmpty)
        #expect(HMPlayerConfiguration.preset(.S2).warmOffsets == [1, -1, 2])
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

        // Also cover unknown duration and clamping in the same snapshot regression.
        snapshot = HMPlaybackSnapshot()
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
}

@Suite("Static playlist source")
struct FeedDataSourceTests {

    @Test("Pages are served in order and loop with unique ids")
    func paginationLoops() async throws {
        let items = (0..<3).map {
            HMMediaItem(id: "item-\($0)", url: URL(string: "https://example.com/\($0).m3u8")!)
        }
        let source = HMStaticPlaylistSource(
            items: items, pageSize: 3, loopsForever: true, simulatedLatency: .zero
        )

        let first = try await source.loadPage(cursor: nil)
        #expect(first.items.map(\.id) == ["item-0", "item-1", "item-2"])

        let second = try await source.loadPage(cursor: first.nextCursor)
        // Ids must stay unique across laps or SwiftUI identity and analytics
        // views both collapse.
        #expect(Set(second.items.map(\.id)).isDisjoint(with: Set(first.items.map(\.id))))
        #expect(second.items.first?.url == items.first?.url)
        let collision = HMMediaItem(id: "__hm_loop_2", url: items[0].url!)
        let tricky = HMStaticPlaylistSource(items: [items[0], collision], pageSize: 2, simulatedLatency: .zero)
        let initial = try await tricky.loadPage(cursor: nil), repeated = try await tricky.loadPage(cursor: "1")
        #expect(Set((initial.items + repeated.items).map(\.id)).count == 4)
    }

    @Test("A finite source terminates instead of looping")
    func finiteSourceEnds() async throws {
        let items = [HMMediaItem(id: "only", url: URL(string: "https://example.com/a.m3u8")!)]
        let source = HMStaticPlaylistSource(
            items: items, pageSize: 1, loopsForever: false, simulatedLatency: .zero
        )
        let first = try await source.loadPage(cursor: nil)
        #expect(first.items.count == 1)
        #expect(first.nextCursor == nil)
        let second = try await source.loadPage(cursor: "1")
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

@Suite("Cache transport primitives")
struct CacheTransportTests {
    @Test("Unchanged windows never restart; cancellation invalidates an epoch; buffer hysteresis prevents churn")
    func epochsAndSafety() {
        #expect(HMPlaybackPriority.isUrgent(displayed: false, stalling: false))
        #expect(HMPlaybackPriority.isUrgent(displayed: false, stalling: true))
        #expect(HMPlaybackPriority.isUrgent(displayed: true, stalling: true))
        #expect(!HMPlaybackPriority.isUrgent(displayed: true, stalling: false))
        #expect(!HMNextWarmSafety.isSafe(ahead: 0.9, remaining: nil, stalling: false, slow: false, wasWarm: false))
        for ahead in [1.01, 0.99, 0.9, 0.26, 0.25] {
            #expect(HMNextWarmSafety.isSafe(ahead: ahead, remaining: nil, stalling: false, slow: false, wasWarm: true))
        }
        #expect(!HMNextWarmSafety.isSafe(ahead: 0.24, remaining: nil, stalling: false, slow: false, wasWarm: true))
        #expect(!HMNextWarmSafety.isSafe(ahead: 3, remaining: nil, stalling: true, slow: false, wasWarm: true))
        #expect(!HMNextWarmSafety.isSafe(ahead: 3, remaining: nil, stalling: false, slow: true, wasWarm: true))
        var epoch = HMPrefetchEpoch()
        let first = epoch.begin("window/config-A")
        for _ in 0..<100 { #expect(epoch.begin("window/config-A") == nil) }
        #expect(epoch.generation == first)
        epoch.cancel()
        #expect(epoch.generation != first)
        #expect(epoch.begin("window/config-A") != nil)
        #expect(epoch.begin("window/config-B") != nil)
        #expect(!HMBufferSafety.isSafe(ahead: 2.9, remaining: 20, hasDuration: true, threshold: 3, wasSafe: false))
        for ahead in [3.1, 2.9, 3.01, 2.99, 1.5] {
            #expect(HMBufferSafety.isSafe(ahead: ahead, remaining: 20, hasDuration: true, threshold: 3, wasSafe: true))
        }
        #expect(!HMBufferSafety.isSafe(ahead: 1.4, remaining: 20, hasDuration: true, threshold: 3, wasSafe: true))
        #expect(HMBufferSafety.isSafe(ahead: 1, remaining: 1, hasDuration: true, threshold: 3, wasSafe: false))
    }

    @Test("Range boundaries, suffixes and invalid multi-ranges")
    func ranges() {
        #expect(HMByteRange.parse("bytes=0-1", total: 100) == HMByteRange(start: 0, end: 1))
        #expect(HMByteRange.parse("bytes=50-", total: 100) == HMByteRange(start: 50, end: 99))
        #expect(HMByteRange.parse("bytes=-10", total: 100) == HMByteRange(start: 90, end: 99))
        #expect(HMByteRange.parse("bytes=0-999", total: 100, limit: 20) == HMByteRange(start: 0, end: 19))
        #expect(HMByteRange.parse("bytes=0-", total: 100, limit: Int.max)?.count == 100)
        for invalid in ["bytes=100-", "bytes=-0", "bytes=2-1", "bytes=-", "bytes=0-1,3-4", "items=0-2", "bytes=x-3"] {
            #expect(HMByteRange.parse(invalid, total: 100) == nil)
        }
    }
    @Test("Only explicitly volatile signing parameters are removed")
    func signatures() {
        let a = URL(string: "https://cdn.example/a.mp4?sig=one")!
        let b = URL(string: "https://cdn.example/a.mp4?sig=two")!
        #expect(HMCacheKey.canonical(a) != HMCacheKey.canonical(b))
        #expect(HMCacheKey.canonical(a, ignoring: ["sig"]) == HMCacheKey.canonical(b, ignoring: ["sig"]))
        let variant = URL(string: "https://cdn.example/a.mp4?variant=720&sig=two")!
        #expect(HMCacheKey.canonical(variant, ignoring: ["sig"]).contains("variant=720"))
        #expect(HMPrefetchPolicy(bytesPerItem: Int.max).bytesPerItem == 8 * 1024 * 1024)
        #expect(HMCacheKey.mime(URL(string: "https://x/a.ts")!) == "video/mp2t")
        #expect(HMCacheKey.mime(URL(string: "https://x/a.vtt")!) == "text/vtt")
        #expect(HMCacheKey.canonical(a) != HMCacheKey.canonical(URL(string: "https://cdn.example/b.mp4")!))
    }
    @Test("HLS relative media, init, key and alternate rendition URIs are rewritten")
    func playlist() async throws {
        let base = URL(string: "https://cdn.example/redirected/variant/index.m3u8?sig=x")!
        let text = "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXT-X-KEY:METHOD=AES-128,URI=\"../key\"\n#EXT-X-MEDIA:TYPE=AUDIO,URI=\"audio.m3u8\"\n#EXTINF:2,\nsegment.m4s\n#EXT-X-BYTERANGE:20@0\nhttps://other.example/a.m4s\n"
        let nonHTTP = "#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://license\"\n#EXT-X-KEY:URI=\"data:text/plain,key\"\ncustom://segment\n"
        #expect(HMPlaylist.rewrite(nonHTTP, base: base) { _ in URL(string: "http://rewritten")! } == nonHTTP)
        #expect(HMPlaylist.references(nonHTTP, base: base).isEmpty)
        let urls = HMPlaylist.references(text, base: base)
        #expect(urls.map(\.absoluteString) == ["https://cdn.example/redirected/variant/init.mp4", "https://cdn.example/redirected/key", "https://cdn.example/redirected/variant/audio.m3u8", "https://cdn.example/redirected/variant/segment.m4s", "https://other.example/a.m4s"])
        let rewritten = HMPlaylist.rewrite(text, base: base) { URL(string: "http://127.0.0.1/" + HMCacheKey.hash($0.absoluteString))! }
        #expect(!rewritten.contains("cdn.example"))
        #expect(rewritten.contains("#EXT-X-BYTERANGE:20@0"))
        #expect(HMPlaylist.references(rewritten, base: base).count == 5)
        let root = URL(string: "https://fixture.example/master.m3u8")!
        let master = "#EXTM3U\r\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio,main\",DEFAULT=YES,URI=\"audio.m3u8\"\r\n#EXT-X-STREAM-INF:BANDWIDTH=800000\r\nfirst.m3u8\r\n#EXT-X-STREAM-INF:BANDWIDTH=1500000,AUDIO=\"audio,main\"\r\nvideo.m3u8\r\n"
        let video = "#EXTM3U\n#EXT-X-MAP:URI=\"parts.mp4\",BYTERANGE=\"4@0\"\n#EXTINF:2,\n#EXT-X-BYTERANGE:8@4\nparts.mp4\n#EXTINF:2,\n#EXT-X-BYTERANGE:8\nparts.mp4\n#EXT-X-ENDLIST\n"
        let audio = "#EXTM3U\n#EXTINF:2,\na.aac\n#EXTINF:2,\nb.aac\n#EXT-X-ENDLIST\n"
        let first = "#EXTM3U\n#EXTINF:2,\nfirst.ts\n#EXT-X-ENDLIST\n"
        let files = [root: Data(master.utf8), root.deletingLastPathComponent().appendingPathComponent("video.m3u8"): Data(video.utf8),
            root.deletingLastPathComponent().appendingPathComponent("audio.m3u8"): Data(audio.utf8),
            root.deletingLastPathComponent().appendingPathComponent("first.m3u8"): Data(first.utf8),
            root.deletingLastPathComponent().appendingPathComponent("parts.mp4"): Data(repeating: 1, count: 20),
            root.deletingLastPathComponent().appendingPathComponent("a.aac"): Data(repeating: 2, count: 4),
            root.deletingLastPathComponent().appendingPathComponent("b.aac"): Data(repeating: 3, count: 4)]
        let manifests = master.utf8.count + video.utf8.count + audio.utf8.count + first.utf8.count
        let loader = HLSFixture(files: files)
        let complete = try await HMHLSPrefetcher(budget: manifests + 28, seconds: 4, cap: 1_600_000).run(root, load: { url, start, count in try await loader.load(url, start, count) })
        #expect(complete.targetMet && complete.seconds == 4 && complete.bytes == manifests + 28)
        let bounded = HLSFixture(files: files)
        let impossible = try await HMHLSPrefetcher(budget: manifests + 15, seconds: 4, cap: 1_600_000).run(root, load: { url, start, count in try await bounded.load(url, start, count) })
        #expect(!impossible.targetMet && impossible.seconds == 0 && impossible.reason == "byte-cap-before-target")
        #expect(await bounded.mediaBodies == 0) // No partial selected audio/video round.
        let variants = HMHLS.variants(master, base: root)
        #expect(HMHLS.startVariant(variants, cap: 1_600_000)?.audioGroup == "audio,main")
        var memory = HMPlaylistMemory<Int>()
        memory.store(7, for: "playlist", owner: "a", immutable: true, now: 0)
        memory.associate("playlist", owner: "b"); memory.retain(owners: ["b"], now: 100, ttl: 1)
        #expect(memory.value(for: "playlist", now: 100, ttl: 1) == 7)
        memory.retain(owners: [], now: 100, ttl: 1); #expect(memory.count == 0)

    }
    @Test("Wasted byte accounting unions probes and intersects delivered ranges")
    func coverage() {
        let fetched = [HMByteRange(start: 0, end: 99), HMByteRange(start: 50, end: 149)]
        let consumed = [HMByteRange(start: 10, end: 19), HMByteRange(start: 15, end: 29), HMByteRange(start: 140, end: 999)]
        #expect(HMRangeCoverage.overlap(fetched, consumed) == 30)
        #expect(HMRangeCoverage.overlap([], consumed) == 0)
    }
    @Test("Controllers share disk ranges; playlists never persist; no-op configure leaves index untouched")
    func disk() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hm-cache-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HMDiskCache.shared(directory: directory, capacity: 12)
        let url = URL(string: "https://example.com/a")!
        await cache.put(key: "a", start: 0, data: Data(0..<8), total: 20, mime: "video/mp4", base: url, owner: "a", prefetched: true, played: false)
        await cache.put(key: "invalid", start: 19, data: Data([1, 2]), total: 20, mime: "video/mp4", base: url, owner: "invalid", prefetched: true, played: false)
        #expect(await cache.bytes(for: "invalid") == 0)
        let hit = await cache.read(key: "a", range: HMByteRange(start: 2, end: 5))
        #expect(hit?.data == Data([2, 3, 4, 5]))
        #expect(await cache.read(key: "a", range: HMByteRange(start: 5, end: 9)) == nil)
        let partial = await cache.available(key: "a", start: 6, count: 6)
        #expect(partial?.data == Data([6, 7]))
        let reopened = HMDiskCache.shared(directory: directory, capacity: 12)
        #expect(cache === reopened)
        #expect(await reopened.bytes(for: "a") == 8)
        await cache.configure(capacity: 12, pinned: ["a"])
        await cache.put(key: "b", start: 0, data: Data(repeating: 9, count: 8), total: 8, mime: "video/mp4", base: url, owner: "b", prefetched: true, played: false)
        #expect(await cache.bytes(for: "a") == 8)
        #expect(await cache.bytes(for: "b") == 0)
        let index = directory.appendingPathComponent("index.json")
        let before = try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date
        await cache.configure(capacity: 12, pinned: ["a"])
        #expect(try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date == before)
        await cache.put(key: "playlist", start: 0, data: Data([1]), total: 1, mime: "application/vnd.apple.mpegurl", base: URL(string: "https://x/index.m3u8?sig=old")!, owner: "playlist", prefetched: true, played: false)
        #expect(await cache.bytes(for: "playlist") == 0)
        await cache.configure(capacity: 4, pinned: ["a"])
        #expect(await cache.bytes(for: "a") == 0)
        #expect(await cache.waste() == 16)
        await cache.configure(capacity: 12, pinned: [])
        await cache.put(key: "shared-segment", start: 0, data: Data(0..<8), total: 8, mime: "video/mp4", base: url, owner: "removed-root", prefetched: true, played: false)
        await cache.release(owners: ["removed-root"], sharedResources: ["shared-segment": "remaining-root"])
        #expect(await cache.bytes(for: "remaining-root") == 8)
        #expect(await cache.read(key: "shared-segment", range: HMByteRange(start: 0, end: 7)) != nil)
        await cache.associate(key: "shared-segment", owner: "hit-owner", played: false)
        await cache.release(owners: ["remaining-root"], sharedResources: [:])
        #expect(await cache.bytes(for: "remaining-root") == 0)
        #expect(await cache.bytes(for: "hit-owner") == 8)
        await cache.release(owners: ["hit-owner"], sharedResources: [:])
        #expect(await cache.read(key: "shared-segment", range: HMByteRange(start: 0, end: 7)) == nil)
    }
}

@Suite("JSONL export")
struct JSONLExportTests {
    @Test("Flush preserves header, event ordering, exact occurrence clock and full configuration")
    @MainActor
    func orderedExport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hm-jsonl-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("run.jsonl")
        let configuration = HMPlayerConfiguration(prefetch: .init(ahead: 5, behind: 1, bytesPerItem: 800_000, secondsPerItem: nil), adaptive: true)
        let sink = try HMJSONLFileSink(fileURL: file, runID: "test", configuration: configuration, format: "mp4", network: "lan", script: "binge", buildSHA: "abc")
        let item = HMMediaItem(id: "a", url: URL(string: "https://example.com/a.mp4")!)
        sink.handle(HMPlaybackEvent(kind: .viewStart, itemID: "a", monotonicTime: 100, metrics: ["request_monotonic_s": 99]), item: item)
        sink.handle(HMPlaybackEvent(kind: .firstFrame, itemID: "a", monotonicTime: 100.25, metrics: ["ttff_ms": 1250]), item: item)
        try await sink.flush()
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        let records = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        #expect(records.count == 3)
        #expect(records[0]["type"] as? String == "runHeader")
        #expect(records[0]["configuration"] as? String == configuration.fingerprint)
        #expect(records[1]["event"] as? String == "viewStart")
        #expect(records[2]["event"] as? String == "firstFrame")
        #expect(records[2]["monotonic_s"] as? Double == 100.25)

        // Benchmark-only snapshots preserve ordering and never reach a partner sink.
        let partner = PartnerSink()
        let hub = HMAnalyticsHub(sinks: [partner])
        let inputs = HMPrefetchInputs(throughputBytesPerSecond: 250_000, bufferedAheadSeconds: 6)
        let plan = HMAdaptivePrefetchPolicy().decide(inputs, configuration: configuration)
        hub.recordPrefetchDecision(inputs: inputs, plan: plan, item: item, policy: "test")
        #expect(partner.events.isEmpty)
        hub.add(sink)
        hub.recordPrefetchDecision(inputs: inputs, plan: plan, item: item, policy: "test")
        hub.emit(HMPlaybackEvent(kind: .playing, itemID: item.id), item: item)
        try await sink.flush()
        #expect(partner.events == [.playing])
        let exported = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        let decision = try JSONSerialization.jsonObject(with: Data(exported[3].utf8)) as! [String: Any]
        let properties = decision["properties"] as! [String: String]
        let recordedPlan = try JSONSerialization.jsonObject(with: Data(properties["plan"]!.utf8)) as! [String: Any]
        #expect(decision["event"] as? String == "prefetchDecision")
        #expect(recordedPlan["bytesPerItem"] as? Int == 131_072)
        #expect(exported[4].contains("playing"))
        hub.remove(named: sink.sinkName)
        hub.recordPrefetchDecision(inputs: inputs, plan: plan, item: item, policy: "test")
        try await sink.flush()
        #expect(try String(contentsOf: file, encoding: .utf8).split(separator: "\n").count == 5)
    }
}

@MainActor private final class PartnerSink: HMAnalyticsSink {
    let sinkName = "partner"
    var events: [HMPlaybackEvent.Kind] = []
    func handle(_ event: HMPlaybackEvent, item: HMMediaItem) { events.append(event.kind) }
}

private actor HLSFixture {
    let files: [URL: Data]
    private(set) var mediaBodies = 0
    init(files: [URL: Data]) { self.files = files }
    func load(_ url: URL, _ start: Int, _ count: Int) async throws -> HMHLSPrefetcher.Response {
        guard let data = files[url], start >= 0, start <= data.count else { throw URLError(.badServerResponse) }
        if count > 0, url.pathExtension != "m3u8" { mediaBodies += 1 }
        return .init(data: count == 0 ? Data() : data.subdata(in: start..<min(data.count, start + count)), total: data.count, base: url)
    }
}
