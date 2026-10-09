import SwiftUI
@_spi(Benchmark) import HotMicPlayer

/// Deterministic, credential-free delayed-reference and terminal-failure repro.
struct ReferenceLabScreen: View {
    @State private var player: HMPlayer
    @State private var serial = 0
    @State private var sink: HMJSONLFileSink?
    private let resolver: ReferenceLabResolver

    init() {
        let resolver = ReferenceLabResolver()
        self.resolver = resolver
        var c = HMPlayerConfiguration(poolSize: 1, prefetch: .off, startsMuted: true, managesAudioSession: false)
        c.resolveAhead = 0
        _player = State(initialValue: HMPlayer(configuration: c, resolver: resolver))
    }
    var body: some View {
        ZStack(alignment: .bottom) {
            HMVerticalFeedView(player: player, gravity: .resizeAspect) { item, snapshot in
                VStack {
                    Text(item.id)
                    Text("\(snapshot.state.rawValue) · \(snapshot.readinessTier.rawValue) · \(String(format: "%.1f", snapshot.currentTime))s")
                        .accessibilityIdentifier("reference-playback")
                    Text("TTFF \(snapshot.timeToFirstFrame.map { String(format: "%.3f", $0) } ?? "pending")")
                    Spacer()
                }.font(.system(size: 14, design: .monospaced)).padding(.top, 100).foregroundStyle(.white)
            }
            VStack(spacing: 8) {
                HStack {
                    Button(player.configuration.failedItemPolicy == .skip ? "Policy: skip" : "Policy: stay") {
                        player.configuration.failedItemPolicy = player.configuration.failedItemPolicy == .skip ? .stay : .skip
                    }
                    Button(player.isInteracting ? "Release scrub" : "Hold scrub") { player.isInteracting.toggle() }
                    Button("Fail end") {
                        serial += 1
                        ReferenceLabEvidence.write(["phase": "action", "operation": "Fail end"])
                        player.replaceAll([seed("previous-\(serial)"), .reference("hotmic", id: "fail-end-\(serial)")], startAt: 1)
                    }
                }
                ForEach(["Initial", "Jump", "Swipe", "Insert"], id: \.self) { operation in
                    HStack {
                        ForEach(["hls", "mp4"], id: \.self) { format in
                            Button("\(operation) \(format.uppercased())") { run(operation, format: format) }
                                .accessibilityIdentifier("ref-\(operation.lowercased())-\(format)")
                        }
                    }
                }
                HStack {
                    Button("Fail middle") { failures(all: false, media: false) }
                    Button("All fail") { failures(all: true, media: false) }
                    Button("Bad media") { failures(all: false, media: true) }
                }
                HStack {
                    Button("Reselect") { player.replaceAll(player.items, startAt: player.activeIndex) }
                    Button("Previous") { player.previous() }
                    Button("Next") { player.next() }
                }
                Text("Swipe in the video above. Each resolver waits 300ms.").font(.caption2)
            }.buttonStyle(.bordered).font(.caption).padding(12).background(.black.opacity(0.85)).foregroundStyle(.white)
        }.background(.black).preferredColorScheme(.dark)
        .task {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            sink = try? HMJSONLFileSink(fileURL: documents.appendingPathComponent("reference-lab-analytics.jsonl"), runID: "reference-lab", configuration: player.configuration, format: "mixed", network: "local", script: "manual", buildSHA: "working-tree")
            if let sink { player.analytics.add(sink) }
            for await event in player.events { ReferenceLabEvidence.write(["phase": "event", "event": String(describing: event), "current": player.currentItem?.id ?? ""]) }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                let s = player.snapshot
                ReferenceLabEvidence.write(["phase": "sample", "current": player.currentItem?.id ?? "", "state": s.state.rawValue,
                    "time": s.currentTime, "frame": s.isFrameReady, "ttff": s.timeToFirstFrame ?? -1,
                    "tier": s.readinessTier.rawValue, "node_active": player.preparedItemCount])
                try? await sink?.flush()
            }
        }
        .onDisappear { player.teardown() }
    }
    private func seed(_ id: String) -> HMMediaItem {
        HMMediaItem(id: id, source: DemoContent.reel[0].source)
    }
    private func run(_ operation: String, format: String) {
        serial += 1
        let id = "\(operation.lowercased())-\(format)-\(serial)"
        let ref = HMMediaItem.reference("hotmic", id: id)
        ReferenceLabEvidence.write(["phase": "action", "operation": operation, "id": ref.id])
        switch operation {
        case "Initial": player.replaceAll([seed("before-\(serial)"), ref], startAt: 1)
        case "Jump": player.replaceAll([seed("seed-\(serial)"), ref]); player.jump(toID: ref.id)
        case "Swipe": player.replaceAll([seed("seed-\(serial)"), ref])
        default: player.replaceAll([seed("seed-\(serial)")]); player.insertNext([ref]); player.next()
        }
    }
    private func failures(all: Bool, media: Bool) {
        serial += 1
        let refs = (0..<3).map { HMMediaItem.reference("hotmic", id: "fail-\(serial)-\($0)") }
        let list = all ? refs : [seed("good-before-\(serial)"), media ? HMMediaItem(id: "bad-media-\(serial)", url: URL(string: "http://127.0.0.1:18088/missing.mp4")!) : refs[1], seed("good-after-\(serial)")]
        ReferenceLabEvidence.write(["phase": "action", "operation": all ? "All fail" : media ? "Bad media" : "Fail middle"])
        player.replaceAll(list, startAt: all ? 0 : 1)
    }
}

private actor ReferenceLabResolver: HMItemResolver {
    func resolve(_ ref: HMMediaItem.Reference) async throws -> HMResolvedItem {
        ReferenceLabEvidence.write(["phase": "resolve-start", "id": ref.id])
        try await Task.sleep(for: .milliseconds(300))
        if ref.id.hasPrefix("fail") { throw HMPlayerError.resolution("Fixture failure") }
        let hls = ref.id.contains("hls")
        let url = hls ? URL(string: "http://127.0.0.1:18088/lab-hls/index.m3u8")! : Bundle.main.url(forResource: "coach-mic", withExtension: "mp4")!
        ReferenceLabEvidence.write(["phase": "resolve-end", "id": ref.id])
        return HMResolvedItem(url: url)
    }
}
private enum ReferenceLabEvidence {
    private static let lock = NSLock()
    static func write(_ row: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        var row = row; row["monotonic"] = ProcessInfo.processInfo.systemUptime
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("reference-lab.jsonl")
        guard var data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        data.append(10)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) { defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data) }
    }
}
