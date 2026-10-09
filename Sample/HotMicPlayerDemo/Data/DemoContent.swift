import Foundation
@_spi(Benchmark) import HotMicPlayer

/// URL-only public defaults. Local files are opt-in and never tracked in Git.
enum DemoContent {
    // Big Buck Bunny © 2008 Blender Foundation, CC BY 3.0.
    // Hosts, attribution and the excerpt's changes are documented in Sample/README.md.
    private static let remote: [HMMediaItem] = [
        HMMediaItem(id: "bunny-mp4",
                    url: URL(string: "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/720/Big_Buck_Bunny_720_10s_1MB.mp4")!,
                    format: .mp4, title: "Big Buck Bunny · MP4 excerpt",
                    author: "© 2008 Blender Foundation · CC BY 3.0", durationHint: 10,
                    metadata: ["series": "Open movies", "source": "remote"]),
        HMMediaItem(id: "bunny-hls",
                    url: URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!,
                    format: .hls, title: "Big Buck Bunny · HLS",
                    author: "© 2008 Blender Foundation · CC BY 3.0",
                    metadata: ["series": "Open movies", "source": "remote"])
    ]

    // Preserve the internal reel's labels when developers supply those files locally.
    private static let localLabels: [String: (title: String, author: String)] = [
        "chiefs-1v1": ("Chiefs rookie 1v1 rep 👀", "@campreport"),
        "practice-grab": ("One-handed grab, no big deal", "@campreport"),
        "fiba-srb-fra": ("Serbia–France, tied up in the second", "@courtside"),
        "rim-cam": ("Rim cam", "@courtside"),
        "coach-mic": ("Coach took the mic", "@lockerroom"),
        "qb1-presser": ("Not ready to name QB1", "@pressroom")
    ]

    private static var local: [HMMediaItem] {
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("LocalMedia"),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return files.filter {
            $0.pathExtension.lowercased() == "mp4" && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
            let id = url.deletingPathExtension().lastPathComponent
            let poster = url.deletingPathExtension().appendingPathExtension("jpg")
            return HMMediaItem(id: id, url: url, format: .mp4,
                               posterURL: FileManager.default.fileExists(atPath: poster.path) ? poster : nil,
                               title: localLabels[id]?.title ?? id.replacingOccurrences(of: "-", with: " "),
                               author: localLabels[id]?.author ?? "Local demo media",
                               metadata: ["source": "local"])
        }
    }

    static var reel: [HMMediaItem] {
        let items = local
        return items.isEmpty ? remote : items
    }

    /// Retains the optional benchmark lab HLS insertion.
    private static func feed(_ reel: [HMMediaItem]) -> [HMMediaItem] {
        guard let origin = BenchmarkOptions().values["feed-hls-origin"],
              let url = URL(string: origin + "/lab-hls/index.m3u8"), ["http", "https"].contains(url.scheme) else { return reel }
        let hls = HMMediaItem(id: "coach-mic-hls", url: url, format: .hls,
                              title: "Local lab · HLS", author: "Local demo media", durationHint: 12,
                              metadata: ["source": "hls"])
        var items = reel
        items.insert(hls, at: min(1, items.count))
        return items
    }

    private static var manifestOption: String? {
        let args = ProcessInfo.processInfo.arguments
        for (index, arg) in args.enumerated() {
            for name in ["--HOTMIC_DEMO_MEDIA_URL", "-HOTMIC_DEMO_MEDIA_URL", "HOTMIC_DEMO_MEDIA_URL"] {
                if arg.hasPrefix(name + "=") { return String(arg.dropFirst(name.count + 1)) }
                if arg == name { return index + 1 < args.count ? args[index + 1] : "" }
            }
        }
        return ProcessInfo.processInfo.environment["HOTMIC_DEMO_MEDIA_URL"]
    }

    static func dataSource() async throws -> HMPlaylistSource {
        let items: [HMMediaItem]
        if let raw = manifestOption {
            guard let url = URL(string: raw), ["https", "http", "file"].contains(url.scheme) else { throw Invalid("manifest URL") }
            let data: Data
            if url.isFileURL { data = try Data(contentsOf: url) }
            else {
                let (body, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Invalid("manifest HTTP status") }
                data = body
            }
            struct Entry: Decodable {
                let id: String
                let url: String
                let poster: String?
                let title: String?
                let author: String?
                let duration: Double?
                let format: String?
            }
            let entries = try JSONDecoder().decode([Entry].self, from: data)
            guard !entries.isEmpty, entries.allSatisfy({ !$0.id.isEmpty }), Set(entries.map(\.id)).count == entries.count else { throw Invalid("empty manifest or duplicate IDs") }
            func resolve(_ value: String) throws -> URL {
                guard let resolved = URL(string: value, relativeTo: url)?.absoluteURL,
                      ["http", "https"].contains(resolved.scheme) || (url.isFileURL && resolved.isFileURL) else { throw Invalid("media/poster URL") }
                return resolved
            }
            items = try entries.map { entry in
                let media = try resolve(entry.url)
                guard entry.format == nil || ["mp4", "hls"].contains(entry.format!),
                      entry.duration == nil || (entry.duration!.isFinite && entry.duration! > 0) else { throw Invalid("format or duration") }
                return HMMediaItem(id: entry.id, url: media,
                                   format: entry.format == "hls" || (entry.format == nil && media.pathExtension.lowercased() == "m3u8") ? .hls : .mp4,
                                   posterURL: try entry.poster.map(resolve), title: entry.title ?? entry.id,
                                   author: entry.author, durationHint: entry.duration, metadata: ["source": "manifest"])
            }
        } else { items = reel }
        let feedItems = feed(items)
        return HMStaticPlaylistSource(items: feedItems, pageSize: feedItems.count, loopsForever: true)
    }

    private struct Invalid: LocalizedError {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { "Invalid demo media: \(reason)" }
    }
}
