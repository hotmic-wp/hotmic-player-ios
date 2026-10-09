import Foundation
@_spi(Benchmark) import HotMicPlayer

/// The demo reel: six bundled vertical clips.
///
/// Add an entry to `clips` and drop `<id>.mp4` plus an `<id>.jpg` poster into
/// `Resources/`. The target uses a synchronized file group, so no project edit
/// is needed.
enum DemoContent {

    // MARK: - Bundled vertical clips

    private struct Clip {
        let id: String
        let title: String
        let author: String
        let series: String
        let duration: TimeInterval
        /// Source aspect, purely so the demo can point at how varied real
        /// vertical inventory is. 9:16, 4:5, 1:1 and square-ish all appear here.
        let aspect: String
    }

    private static let clips: [Clip] = [
        Clip(id: "chiefs-1v1", title: "Chiefs rookie 1v1 rep 👀", author: "@campreport",
             series: "Camp", duration: 10.8, aspect: "9:16"),
        Clip(id: "practice-grab", title: "One-handed grab, no big deal", author: "@campreport",
             series: "Camp", duration: 16.6, aspect: "4:5"),
        Clip(id: "fiba-srb-fra", title: "Serbia–France, tied up in the second", author: "@courtside",
             series: "Hoops", duration: 8.7, aspect: "1:1"),
        Clip(id: "rim-cam", title: "Rim cam", author: "@courtside",
             series: "Hoops", duration: 30.5, aspect: "3:4"),
        Clip(id: "coach-mic", title: "Coach took the mic", author: "@lockerroom",
             series: "Locker Room", duration: 42.4, aspect: "9:19"),
        Clip(id: "qb1-presser", title: "Not ready to name QB1", author: "@pressroom",
             series: "Presser", duration: 17.4, aspect: "9:16")
    ]

    private static func bundled(_ clip: Clip) -> HMMediaItem? {
        guard let url = Bundle.main.url(forResource: clip.id, withExtension: "mp4") else { return nil }
        return HMMediaItem(
            id: clip.id,
            url: url,
            posterURL: Bundle.main.url(forResource: clip.id, withExtension: "jpg"),
            title: clip.title,
            author: clip.author,
            durationHint: clip.duration,
                        metadata: ["series": clip.series, "aspect": clip.aspect, "source": "bundle"]
        )
    }

    static let reel: [HMMediaItem] = clips.compactMap(bundled)

    static var dataSource: HMPlaylistSource {
        HMStaticPlaylistSource(items: reel, pageSize: reel.count, loopsForever: true)
    }
}
