import SwiftUI
import HotMicPlayer

/// The "prove it's fast" panel.
///
/// Time-to-first-frame is the number the whole preload design exists to move,
/// so it gets top billing and a colour-coded verdict.
struct DebugHUDView: View {

    let snapshot: HMPlaybackSnapshot
    let poolBusy: Int
    let poolSize: Int
    let prefetchLabel: String

    private var ttffMilliseconds: Double? {
        snapshot.timeToFirstFrame.map { $0 * 1000 }
    }

    private var ttffColor: Color {
        guard let ms = ttffMilliseconds else { return .white.opacity(0.5) }
        if ms < 250 { return .green }
        if ms < 700 { return .yellow }
        return DemoTheme.accentHot
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(ttffColor).frame(width: 7, height: 7)
                    Text("TTFF")
                        .font(DemoTheme.label(10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                    Text(ttffMilliseconds.map { String(format: "%.0f ms", $0) } ?? "—")
                        .font(DemoTheme.metric(17, weight: .bold))
                        .foregroundStyle(ttffColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                }
                Text(snapshot.wasPreloaded ? "PRELOADED" : "COLD START")
                    .font(DemoTheme.label(8, weight: .black))
                    .foregroundStyle(snapshot.wasPreloaded ? .black : .white.opacity(0.8))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(
                        snapshot.wasPreloaded ? AnyShapeStyle(DemoTheme.accent) : AnyShapeStyle(.white.opacity(0.15)),
                        in: .capsule
                    )
            }

            Divider().overlay(.white.opacity(0.15))

            grid

            Text("tap to hide")
                .font(DemoTheme.label(9))
                .foregroundStyle(.white.opacity(0.3))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(11)
        .background(.black.opacity(0.55), in: .rect(cornerRadius: 14))
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.12), lineWidth: 0.5))
        .frame(width: 194)
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 3) {
            row("state", snapshot.state.rawValue)
            row("time", snapshot.isLive
                ? "live · \(EmojiScrubberView.timecode(snapshot.seekableDuration)) dvr"
                : "\(EmojiScrubberView.timecode(snapshot.currentTime)) / \(EmojiScrubberView.timecode(snapshot.duration))")
            row("bitrate", snapshot.indicatedBitrate > 0
                ? String(format: "%.1f Mbps", snapshot.indicatedBitrate / 1_000_000)
                : "—")
            row("buffered", String(format: "%.1fs", snapshot.bufferedAhead))
            row("stalls", snapshot.stallCount == 0
                ? "0"
                : String(format: "%d · %.1fs", snapshot.stallCount, snapshot.totalStallDuration))
            row("pool", "\(poolBusy)/\(poolSize) busy")
            row("prefetch", prefetchLabel)
            if let error = snapshot.errorDescription {
                row("error", error).foregroundStyle(DemoTheme.accentHot)
            }
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(DemoTheme.label(10))
                .foregroundStyle(.white.opacity(0.5))
            Spacer(minLength: 4)
            Text(value)
                .font(DemoTheme.metric(11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)
        }
    }
}
