import Foundation

struct BenchmarkGrid: Decodable {
    let runPrefix: String
    let resultsURL: String
    let network: String
    let cells: [Cell]
    enum CodingKeys: String, CodingKey { case runPrefix = "run_prefix", resultsURL = "results_url", network, cells }
    struct Cell: Decodable {
        let id: String
        let strategy: String
        let format: String
        let playlistURL: String
        let script: String
        let repeats: Int
        let swipes: Int?
        let knobs: [String: Double]?
        let dwellSeconds: Double?
        let resetCache: Bool?
        let requireFrame: Bool?
        enum CodingKeys: String, CodingKey {
            case id, strategy, format, script, repeats, swipes, knobs
            case playlistURL = "playlist_url", dwellSeconds = "dwell_seconds", resetCache = "reset_cache", requireFrame = "require_frame"
        }
    }
}
