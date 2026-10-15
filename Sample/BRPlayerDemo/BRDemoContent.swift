import Foundation
import HotMicPlayer

/// Placeholder BR clips on the benchmark CDN, replaced by the demo content set when it lands.
enum BRDemoContent {
    private static let base = URL(string: "https://d1s9ql8g8ygo3y.cloudfront.net/content/")!
    private struct Clip {
        let id: String
        let rendition: String
        let title: String
        let seconds: Double
        let aspect: Double
    }
    private static let clips: [Clip] = [
        Clip(id: "b583313c-3af8-492a-91b0-eb8cc4b0e1f3", rendition: "mp4-faststart-540.mp4",
             title: "Reaves threw this lob to the sky 😅", seconds: 7.43, aspect: 9.0 / 16),
        Clip(id: "03c60a49-3d60-4218-b837-7ffb7902335e", rendition: "mp4-faststart-720.mp4",
             title: "Haliburton tells McAfee he added significant muscle", seconds: 9.29, aspect: 9.0 / 16),
        Clip(id: "8e454202-8d19-478e-a429-c227480222bf", rendition: "mp4-faststart-720.mp4",
             title: "Field view of the Contreras HR", seconds: 34.39, aspect: 4.0 / 5),
        Clip(id: "fab78152-07b3-4927-8c6d-d08f5a2b8830", rendition: "mp4-faststart-720.mp4",
             title: "Falcons are on FIRE", seconds: 55.37, aspect: 16.0 / 9),
        Clip(id: "8bb581ba-ce6b-4f3e-890f-78fe73304876", rendition: "mp4-faststart-720.mp4",
             title: "A'ja Wilson is the 2026 WNBA MVP", seconds: 10.7, aspect: 9.0 / 16),
        Clip(id: "55655970-5cd5-417f-bc3d-80c0528e1207", rendition: "mp4-faststart-720.mp4",
             title: "Bijan over Gibbs in the NFL MVP rankings", seconds: 29.91, aspect: 9.0 / 16)
    ]
    static var items: [HMMediaItem] {
        clips.map { clip in
            let folder = base.appendingPathComponent(clip.id, isDirectory: true)
            return HMMediaItem(id: clip.id, url: folder.appendingPathComponent(clip.rendition), format: .mp4,
                               posterURL: folder.appendingPathComponent("poster.jpg"), title: clip.title,
                               durationHint: clip.seconds, aspectRatio: clip.aspect)
        }
    }
    static let landscapeID = "fab78152-07b3-4927-8c6d-d08f5a2b8830"
}
