import SwiftUI
@_spi(Benchmark) import HotMicPlayer

/// Playlist operations use the public SDK; animation and diagnostics use Benchmark SPI.
struct PlaylistLabScreen: View {
    let onBack: () -> Void
    @State private var player = HMPlayer()
    @State private var serial = 0
    @State private var rankedRefresh = false
    @State private var rankedTask: Task<Void, Never>?
    @State private var rankedTick = 0
    @State private var status = "Preparing mixed VOD playlist"
    @State private var origin = BenchmarkOptions().values["lab-origin"] ?? "http://127.0.0.1:8088"
    @State private var delayed: Task<Void, Never>?
    @State private var sink: HMJSONLFileSink?
    @State private var offlineRun: String?
    @Environment(\.scenePhase) private var scenePhase
    @State private var changes: [String] = []

    var body: some View {
        ZStack(alignment: .bottom) {
            HMVerticalFeedView(player: player, gravity: .resizeAspect) { item, snapshot in
                VStack {
                    Text(item.title ?? item.id).font(.headline)
                    Text("\(snapshot.state.rawValue) · \(snapshot.readinessTier.rawValue) · \(String(format: "%.1fs", snapshot.currentTime)) · stalls \(snapshot.stallCount)")
                        .font(.system(size: 12, design: .monospaced))
                        .accessibilityIdentifier("lab-playback")
                    Spacer()
                }.padding(.top, 100).foregroundStyle(.white)
            }
            VStack(spacing: 8) {
                HStack { Button("Back", action: onBack); Spacer(); Text("Playlist lab").bold(); Spacer(); Button(player.isMuted ? "Unmute" : "Mute") { player.isMuted.toggle() } }
                TextField("Bench origin URL", text: $origin).textInputAutocapitalization(.never).autocorrectionDisabled().font(.caption)
                    .accessibilityIdentifier("lab-origin")
                HStack {
                    operationButton("Replace all", "replaceAll") { player.replaceAll(batch()) }
                    operationButton("Upcoming", "replaceUpcoming") { player.replaceUpcoming(batch()) }
                    operationButton("Insert next", "insertNext") { player.insertNext(batch()) }
                }
                HStack {
                    operationButton("Append", "append") { player.append(batch()) }
                    operationButton("Remove next", "remove-next") { player.remove(ids: Set(player.items.dropFirst(player.activeIndex + 1).prefix(1).map(\.id))) }
                    operationButton("Remove current", "remove-current") { player.remove(ids: Set(player.currentItem.map { [$0.id] } ?? [])) }
                }
                HStack {
                    operationButton("Clear", "clear") { player.remove(ids: Set(player.items.map(\.id))) }
                    operationButton("Duplicate", "duplicate") { player.append(player.currentItem.map { [$0] } ?? []) }
                    Button("Edit in swipe") {
                        editDuringSwipe(replace: true)
                    }.accessibilityIdentifier("lab-mid-swipe")
                }
                HStack {
                    Button("Paging race") { startPagingRace() }.accessibilityIdentifier("lab-paging-race")
                    Button("Append in swipe") { editDuringSwipe(replace: false) }.accessibilityIdentifier("lab-append-swipe")
                    operationButton("No-op", "no-op") { player.append([]) && player.insertNext([]) && player.remove(ids: ["unknown"]) }
                }
                HStack {
                    Button("Offline paging") { startOfflinePaging() }.accessibilityIdentifier("lab-offline-paging")
                    Button("Retry page") {
                        LabEvidence.append(["run": offlineRun ?? "", "phase": "explicit-retry", "monotonic": ProcessInfo.processInfo.systemUptime], to: "playlist-lab-offline.jsonl")
                        Task { await player.loadNextPage() }
                    }.accessibilityIdentifier("lab-retry-page")
                    Text(player.isLoadingPage ? "Loading page" : "Page idle").accessibilityIdentifier("lab-page-state")
                }
                Toggle("Ranked feed refresh (3s, finish once)", isOn: $rankedRefresh)
                    .accessibilityIdentifier("lab-ranked-refresh")
                HStack {
                    Button("Previous") { player.previous() }
                    Button(player.snapshot.state == .paused ? "Play" : "Pause") { player.togglePlayPause() }
                    Button("Seek +2s") { player.seek(to: player.snapshot.currentTime + 2) }
                    Button("Next") { player.next() }
                }.font(.caption)
                Text(status).font(.caption2).accessibilityIdentifier("lab-status").lineLimit(2)
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(player.items) { item in
                            Button { player.jump(toID: item.id) } label: {
                                let snapshot = player.snapshot(for: item)
                                Text("\(player.currentItem?.id == item.id ? "▶" : "·") \(item.id) · \(item.format.rawValue) · \(snapshot.state.rawValue)")
                                    .font(.system(size: 10, design: .monospaced))
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 75).accessibilityIdentifier("lab-list")
            }
            .buttonStyle(.bordered).font(.system(size: 10)).padding(10)
            .background(.black.opacity(0.85)).foregroundStyle(.white)
        }
        .background(.black).preferredColorScheme(.dark)
        .task {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            if let file = try? HMJSONLFileSink(fileURL: documents.appendingPathComponent("BenchRuns/playlist-lab-\(UUID().uuidString).jsonl"), runID: "playlist-lab", configuration: player.configuration, format: "mixed", network: "local", script: "playlist-lab", buildSHA: "working-tree") {
                sink = file; player.analytics.add(file)
            }
            if BenchmarkOptions().values["ranked-refresh"] == "1" {
                rankedRefresh = true; startRankedRefresh()
            } else { player.replaceAll(batch()) }
            status = "Swipe above the controls; operations preserve the settled current item"
            for await event in player.events {
                if case let .error(_, kind) = event { status = kind.localizedDescription }
                if case let .sourcePageDuplicates(ids) = event { status = "Source dropped duplicates: " + ids.joined(separator: ",") }
                recordEvent(event)
            }
        }
        .onChange(of: rankedRefresh) { _, enabled in
            if enabled { startRankedRefresh() } else { rankedTask?.cancel(); rankedTask = nil }
        }
        .onChange(of: scenePhase) { _, phase in
            player.isFeedVisible = phase == .active
            perform("scene-" + String(describing: phase)) { true }
        }
        .onDisappear { rankedTask?.cancel(); delayed?.cancel(); player.teardown(); Task { try? await sink?.flush() } }
    }
    /// A complete ranked response every three seconds, including edits while the feed is scrolling.
    private func startRankedRefresh() {
        guard rankedTask == nil else { return }
        var configuration = player.configuration
        configuration.removedCurrentPolicy = .finishThenAdvance
        configuration.loops = true; configuration.adaptive = false
        player.configuration = configuration
        let seeds = (0..<12).map { index in
            HMMediaItem(id: "ranked-\(index)", url: URL(string: origin + "/item-\(index % 8)/clip.mp4")!,
                        title: "Ranked clip \(index)", durationHint: 10)
        }
        player.replaceAll(seeds); rankedTick = 0
        rankedTask = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                rankedTick += 1
                let tick = rankedTick
                // Use the same view-driven animated swipe path as benchmark automation.
                if tick == 3 || tick == 6 { player.requestPage(at: player.activeIndex + 1) }
                switch tick {
                case 7:
                    // Real end notification follows the seek; loops remains true throughout.
                    perform("finish-once-remove") { player.reconcile(player.items.filter { $0.id != player.currentItem?.id }) }
                    if player.snapshot.duration > 1 { player.seek(to: player.snapshot.duration - 1) }
                case 10:
                    perform("finish-swipe-remove") { player.remove(ids: Set(player.currentItem.map { [$0.id] } ?? [])) }
                    player.requestPage(at: player.activeIndex + 1)
                default:
                    if tick % 3 == 1 {
                        perform("ranked-identical-replaceAll") { player.replaceAll(player.items, startAt: player.activeIndex) }
                    } else if tick % 3 == 2 {
                        let refreshed = player.items.map { item in
                            HMMediaItem(id: item.id, source: item.source, posterURL: item.posterURL,
                                title: "Refresh \(tick): \(item.id)", author: item.author,
                                durationHint: item.durationHint, metadata: ["refresh": String(tick)])
                        }
                        perform("ranked-metadata-replaceAll") { player.replaceAll(refreshed, startAt: player.activeIndex) }
                    } else {
                        var ranked = player.items
                        // Re-rank the tail, leaving current and its nearest prepared neighbour intact.
                        if ranked.count > player.activeIndex + 4 { ranked.swapAt(ranked.count - 1, ranked.count - 2) }
                        perform("ranked-reconcile") { player.reconcile(ranked) }
                    }
                }
                if tick >= 12 {
                    LabEvidence.append(["phase": "ranked-complete"], to: "playlist-lab-operations.jsonl")
                    return
                }
            }
        }
    }
    private func editDuringSwipe(replace: Bool) {
        delayed?.cancel()
        player.requestPage(at: player.activeIndex + 1)
        delayed = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            perform(replace ? "mid-swipe-replace" : "mid-swipe-append") {
                replace ? player.replaceUpcoming(batch()) : player.append(batch())
            }
        }
    }
    private func startPagingRace() {
        delayed?.cancel(); player.playlistSource = nil
        var configuration = player.configuration; configuration.lowWaterMark = 2
        player.configuration = configuration
        let seeds = batch() + batch() + batch()
        let additions = batch() + batch()
        player.replaceAll(seeds, startAt: 2)
        player.playlistSource = LabPlaylistSource(pages: [
            HMPlaylistPage(items: [seeds[3], additions[0], additions[0]], nextCursor: "overlap-2"),
            HMPlaylistPage(items: [additions[0], additions[1]], nextCursor: "overlap-3"),
            HMPlaylistPage(items: [additions[1], additions[2], additions[3]], nextCursor: nil)
        ])
        // Settling at index 3 crosses the low-water mark. Swipe again while the
        // delayed request is active, or use Append in swipe to race a partner edit.
        delayed = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            player.requestPage(at: 3)
        }
        status = "Paging race: swipe while loading; each page overlaps. Cursor log in Documents."
    }
    private func startOfflinePaging() {
        delayed?.cancel(); player.playlistSource = nil
        var configuration = player.configuration
        configuration.prefetch = .off; configuration.lowWaterMark = 1
        player.configuration = configuration
        serial += 1
        let seeds = DemoContent.reel.prefix(4).enumerated().map { offset, clip in
            HMMediaItem(id: "offline-\(serial)-\(offset)", source: clip.source, title: clip.title, durationHint: clip.durationHint)
        }
        player.replaceAll(seeds, startAt: max(0, seeds.count - 2))
        let run = UUID().uuidString; offlineRun = run
        // An unavailable local paging origin reproduces a real URLSession failure
        // without changing the simulator or host's shared network settings.
        player.playlistSource = LabOfflinePlaylistSource(url: URL(string: origin + "/offline-playlist.json")!, run: run)
        Task { await player.loadNextPage() }
        status = "Offline origin: four attempts with 1/2/4s waits, then idle. Next or Retry page resets the cap."
    }
    private func recordEvent(_ event: HMPlayerEvent) {
        let row: [String: Any] = ["event": String(describing: event), "current": player.currentItem?.id ?? "",
            "items": player.items.map(\.id), "loading": player.isLoadingPage, "monotonic": ProcessInfo.processInfo.systemUptime]
        LabEvidence.append(row, to: "playlist-lab-events.jsonl")
        if let offlineRun, case let .error(_, kind) = event {
            LabEvidence.append(["run": offlineRun, "phase": "error-event", "error": kind.localizedDescription,
                "monotonic": ProcessInfo.processInfo.systemUptime], to: "playlist-lab-offline.jsonl")
        }
    }
    private func operationButton(_ title: String, _ id: String, action: @escaping () -> Bool) -> some View {
        Button(title) { perform(id, action: action) }.accessibilityIdentifier("lab-\(id)")
    }
    private func batch() -> [HMMediaItem] {
        serial += 1
        let reel = DemoContent.reel
        guard !reel.isEmpty else { return [] }
        let clip = reel[serial % reel.count]
        let mp4 = HMMediaItem(id: "lab-\(serial)-mp4", source: clip.source, posterURL: clip.posterURL,
                              title: clip.title, durationHint: clip.durationHint)
        guard let hlsURL = URL(string: origin + "/lab-hls/index.m3u8"), ["http", "https"].contains(hlsURL.scheme) else { return [mp4] }
        let hls = HMMediaItem(id: "lab-\(serial)-hls", url: hlsURL, format: .hls,
                              title: "Bench HLS VOD", durationHint: 12)
        return [mp4, hls]
    }
    private func perform(_ name: String, action: () -> Bool) {
        let before = player.snapshot, oldID = player.currentItem?.id
        let beforePlayers = player.preparedItemIdentities
        let beforeBuffers = Dictionary(uniqueKeysWithValues: player.items.filter { beforePlayers[$0.id] != nil }.map {
            ($0.id, player.snapshot(for: $0).bufferedAhead)
        })
        let warmTiers = Dictionary(uniqueKeysWithValues: player.items.filter { beforePlayers[$0.id] != nil }.map {
            ($0.id, player.snapshot(for: $0).readinessTier.rawValue)
        })
        let accepted = action(), after = player.snapshot
        let preserved = oldID == player.currentItem?.id && before.activationID == after.activationID && before.currentTime == after.currentTime && before.isFrameReady == after.isFrameReady && before.stallCount == after.stallCount
        status = "\(name): \(accepted ? "accepted" : "rejected") · \(preserved ? "current preserved" : "current changed")"
        let record: [String: Any] = ["operation": name, "accepted": accepted, "current_preserved": preserved,
            "before_id": oldID ?? "", "after_id": player.currentItem?.id ?? "", "before_activation": before.activationID,
            "after_activation": after.activationID, "before_time": before.currentTime, "after_time": after.currentTime,
            "before_frame": before.isFrameReady, "after_frame": after.isFrameReady, "stalls": after.stallCount,
            "before_players": beforePlayers, "after_players": player.preparedItemIdentities,
            "before_buffers": beforeBuffers,
            "after_buffers": Dictionary(uniqueKeysWithValues: player.items.filter { player.preparedItemIdentities[$0.id] != nil }.map { ($0.id, player.snapshot(for: $0).bufferedAhead) }),
            "warm_tiers": warmTiers, "released_ids": player.lastPlaylistChange?.releasedItemIDs ?? [],
            "removed_ids": player.lastPlaylistChange?.removedIDs ?? [],
            "loops": player.configuration.loops, "prepared_items": player.preparedItemCount, "items": player.items.map(\.id), "revision": player.playlistRevision, "monotonic": ProcessInfo.processInfo.systemUptime]
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), let line = String(data: data, encoding: .utf8) {
            changes.append(line)
            let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("playlist-lab-operations.jsonl")
            try? (changes.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        }
        Task { try? await sink?.flush() }
    }
}

private actor LabPlaylistSource: HMPlaylistSource {
    let pages: [HMPlaylistPage]
    init(pages: [HMPlaylistPage]) { self.pages = pages }
    func loadPage(cursor: String?) async throws -> HMPlaylistPage {
        let index = cursor.flatMap { Int($0.split(separator: "-").last ?? "") }.map { $0 - 1 } ?? 0
        LabEvidence.append(["cursor": cursor ?? "nil", "phase": "request", "monotonic": ProcessInfo.processInfo.systemUptime], to: "playlist-lab-pages.jsonl")
        try await Task.sleep(for: .seconds(2))
        let page = pages[index]
        LabEvidence.append(["cursor": cursor ?? "nil", "next": page.nextCursor ?? "end", "phase": "response", "ids": page.items.map(\.id), "monotonic": ProcessInfo.processInfo.systemUptime], to: "playlist-lab-pages.jsonl")
        return page
    }
}

private actor LabOfflinePlaylistSource: HMPlaylistSource {
    let url: URL
    let run: String
    private var attempts = 0
    init(url: URL, run: String) { self.url = url; self.run = run }
    func loadPage(cursor: String?) async throws -> HMPlaylistPage {
        attempts += 1
        let row: [String: Any] = ["run": run, "attempt": attempts, "cursor": cursor ?? "nil",
            "phase": "request", "monotonic": ProcessInfo.processInfo.systemUptime]
        LabEvidence.append(row, to: "playlist-lab-offline.jsonl")
        do {
            var request = URLRequest(url: url); request.timeoutInterval = 1
            let (_, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            return HMPlaylistPage(items: [], nextCursor: nil)
        } catch {
            var failure = row; failure["phase"] = "failure"; failure["error"] = String(describing: error)
            failure["monotonic"] = ProcessInfo.processInfo.systemUptime
            LabEvidence.append(failure, to: "playlist-lab-offline.jsonl")
            throw error
        }
    }
}

private enum LabEvidence {
    private static let lock = NSLock()
    static func append(_ record: [String: Any], to name: String) {
        lock.lock(); defer { lock.unlock() }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
        guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        data.append(10)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) { defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data) }
    }
}
