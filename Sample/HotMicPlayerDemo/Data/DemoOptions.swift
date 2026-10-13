import Foundation
import HotMicPlayer

/// Small host launch adapter for demo screens and opt-in public regression manifests.
/// There are no strategy grids, benchmark knobs, uploads or run orchestration.
struct DemoOptions {
    let values: [String: String]
    init(environment: [String: String] = ProcessInfo.processInfo.environment, arguments: [String] = ProcessInfo.processInfo.arguments) {
        var result: [String: String] = [:]
        for (key, value) in environment where key.hasPrefix("HM_") {
            result[String(key.dropFirst(3)).lowercased().replacingOccurrences(of: "_", with: "-")] = value
        }
        var i = 1
        while i < arguments.count {
            if arguments[i].hasPrefix("--hm-"), i + 1 < arguments.count {
                result[String(arguments[i].dropFirst(5))] = arguments[i + 1]; i += 2
            } else { i += 1 }
        }
        values = result
    }
    var startIndex: Int { Int(values["start-index"] ?? "0") ?? 0 }
    func dataSource() async throws -> any HMPlaylistSource {
        guard let raw = values["manifest-url"] else { return try await DemoContent.dataSource() }
        guard let url = URL(string: raw), ["http", "https", "file"].contains(url.scheme) else { throw Invalid("manifest URL") }
        let data: Data
        if url.isFileURL { data = try Data(contentsOf: url) }
        else {
            let (body, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Invalid("manifest HTTP status") }
            data = body
        }
        struct Entry: Decodable {
            let id: String; let url: String; let poster: String?; let format: String?
            let duration: Double?; let aspectRatio: Double?; let captions: [String: String]?
        }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        guard !entries.isEmpty, entries.allSatisfy({ !$0.id.isEmpty }), Set(entries.map(\.id)).count == entries.count else { throw Invalid("empty manifest or duplicate IDs") }
        func resolve(_ raw: String) throws -> URL {
            guard let resolved = URL(string: raw, relativeTo: url)?.absoluteURL,
                  ["http", "https"].contains(resolved.scheme) || (url.isFileURL && resolved.isFileURL) else { throw Invalid("media URL") }
            return resolved
        }
        let items = try entries.map { entry -> HMMediaItem in
            guard entry.format == nil || ["mp4", "hls"].contains(entry.format!),
                  entry.duration == nil || (entry.duration!.isFinite && entry.duration! > 0),
                  entry.aspectRatio == nil || (entry.aspectRatio!.isFinite && entry.aspectRatio! > 0) else { throw Invalid("media hints") }
            let media = try resolve(entry.url)
            return HMMediaItem(id: entry.id, url: media,
                format: entry.format == "hls" || (entry.format == nil && media.pathExtension == "m3u8") ? .hls : .mp4,
                posterURL: try entry.poster.map(resolve), title: entry.id, durationHint: entry.duration,
                aspectRatio: entry.aspectRatio, captionSources: try (entry.captions ?? [:]).mapValues(resolve))
        }
        return HMStaticPlaylistSource(items: items, pageSize: items.count, loopsForever: false, simulatedLatency: .zero)
    }
    struct Invalid: LocalizedError {
        let key: String
        init(_ key: String) { self.key = key }
        var errorDescription: String? { "Invalid demo input: \(key)" }
    }
}
