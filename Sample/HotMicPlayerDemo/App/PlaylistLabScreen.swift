import SwiftUI
import HotMicPlayer

/// All interactions here compile against the public SDK, including the diagnostic snapshots.
struct PlaylistLabScreen: View {
    let onBack: () -> Void
    @State private var player = HMPlayer()
    @State private var serial = 0
    @State private var status = "Preparing mixed VOD playlist"
    @State private var origin = BenchmarkOptions().values["lab-origin"] ?? "http://127.0.0.1:8088"
    @State private var delayed: Task<Void, Never>?
    @State private var sink: HMJSONLFileSink?
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
                        delayed?.cancel(); status = "Animating a page move; editing before it settles"
                        player.requestPage(at: player.activeIndex + 1)
                        delayed = Task { @MainActor in
                            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                            perform("mid-swipe") { player.replaceUpcoming(batch()) }
                        }
                    }.accessibilityIdentifier("lab-mid-swipe")
                }
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
            player.replaceAll(batch())
            status = "Swipe above the controls; operations preserve the settled current item"
            for await event in player.events {
                if case let .error(_, kind) = event { status = kind.localizedDescription }
            }
        }
        .onDisappear { delayed?.cancel(); player.teardown(); Task { try? await sink?.flush() } }
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
        let accepted = action(), after = player.snapshot
        let preserved = oldID == player.currentItem?.id && before.activationID == after.activationID && before.currentTime == after.currentTime && before.isFrameReady == after.isFrameReady && before.stallCount == after.stallCount
        status = "\(name): \(accepted ? "accepted" : "rejected") · \(preserved ? "current preserved" : "current changed")"
        let record: [String: Any] = ["operation": name, "accepted": accepted, "current_preserved": preserved,
            "before_id": oldID ?? "", "after_id": player.currentItem?.id ?? "", "before_activation": before.activationID,
            "after_activation": after.activationID, "before_time": before.currentTime, "after_time": after.currentTime,
            "before_frame": before.isFrameReady, "after_frame": after.isFrameReady, "stalls": after.stallCount,
            "items": player.items.map(\.id), "revision": player.playlistRevision, "monotonic": ProcessInfo.processInfo.systemUptime]
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), let line = String(data: data, encoding: .utf8) {
            changes.append(line)
            let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("playlist-lab-operations.jsonl")
            try? (changes.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        }
        Task { try? await sink?.flush() }
    }
}
