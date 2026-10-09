import SwiftUI
@_spi(Benchmark) import HotMicPlayer

/// The timeline scrubber: an engagement waveform that fills as you watch,
/// clustered emoji markers over the peaks, and a glowing playhead.
///
/// Built so that *playback does not redraw it*. The bars are a `Shape` whose
/// geometry depends only on the density array, drawn twice — dim underneath,
/// bright on top — with the bright copy revealed by a mask whose width is the
/// only thing a time tick changes. Scrubbing a 40-minute clip costs one mask
/// resize per frame, not a path rebuild.
struct EmojiScrubberView: View {

    let progress: Double
    let bufferedProgress: Double
    let density: [HMDensityBucket]
    let markers: [HMTimelineMarker]
    let duration: TimeInterval
    let isLive: Bool
    let onScrub: (Double) -> Void
    let onScrubStateChange: (Bool) -> Void

    @State private var isScrubbing = false
    @State private var scrubProgress: Double = 0

    private var displayProgress: Double { isScrubbing ? scrubProgress : progress }
    private var barHeight: CGFloat { isScrubbing ? 40 : 26 }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height

            ZStack(alignment: .bottomLeading) {
                waveform(width: width)
                markerRail(width: width, height: height)
                liveEdge(width: width)
                playhead(width: width)
                if isScrubbing { readout(width: width) }
            }
            .frame(width: width, height: height, alignment: .bottom)
            .contentShape(.rect)
            .gesture(scrubGesture(width: width))
        }
        // Grows upward while scrubbing to make room for the timecode bubble.
        .frame(height: isScrubbing ? 92 : 58)
        .animation(.snappy(duration: 0.22), value: isScrubbing)
    }

    // MARK: - Layers

    private func waveform(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            // Unwatched.
            EngagementBars(density: density)
                .fill(.white.opacity(0.22))

            // Buffered but not yet watched — a touch brighter.
            EngagementBars(density: density)
                .fill(.white.opacity(0.32))
                .mask(alignment: .leading) {
                    Rectangle().frame(width: width * clamped(bufferedProgress))
                }

            // Watched.
            EngagementBars(density: density)
                .fill(
                    LinearGradient(
                        colors: [DemoTheme.accent, DemoTheme.accentHot],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .mask(alignment: .leading) {
                    Rectangle().frame(width: width * clamped(displayProgress))
                }
                .shadow(color: DemoTheme.accent.opacity(0.5), radius: 6, y: 1)
        }
        .frame(height: barHeight)
    }

    private func markerRail(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            ForEach(markers) { marker in
                Text(marker.emoji)
                    .font(.system(size: isScrubbing ? 18 : 13))
                    .shadow(color: .black.opacity(0.65), radius: 3)
                    .position(x: marker.position * width, y: height - barHeight - 12)
            }
        }
        .allowsHitTesting(false)
    }

    /// A live stream's rail is the DVR window, so the right-hand end *is* the
    /// live edge and deserves to be marked as such.
    @ViewBuilder
    private func liveEdge(width: CGFloat) -> some View {
        if isLive {
            Circle()
                .fill(DemoTheme.live)
                .frame(width: 7, height: 7)
                .shadow(color: DemoTheme.live.opacity(0.9), radius: 5)
                .offset(x: width - 7, y: -barHeight / 2 + 3.5)
                .allowsHitTesting(false)
        }
    }

    private func playhead(width: CGFloat) -> some View {
        Capsule()
            .fill(.white)
            .frame(width: 3, height: barHeight + 10)
            .shadow(color: .white.opacity(0.7), radius: isScrubbing ? 8 : 4)
            .overlay(alignment: .top) {
                Circle()
                    .fill(.white)
                    .frame(width: isScrubbing ? 10 : 6, height: isScrubbing ? 10 : 6)
                    .offset(y: -3)
            }
            .offset(x: width * clamped(displayProgress) - 1.5)
            .allowsHitTesting(false)
    }

    /// Floating timecode that tracks the thumb, with a summary of what happened
    /// at that point — the payoff of keeping a density index around.
    private func readout(width: CGFloat) -> some View {
        let target = displayProgress * duration
        let nearby = density.first { abs($0.position - displayProgress) < 0.02 }

        return HStack(spacing: 6) {
            Text(Self.timecode(target))
                .font(DemoTheme.metric(13, weight: .bold))
            if let nearby, nearby.eventCount > 0 {
                Text("\(nearby.dominantEmoji ?? "💬") \(nearby.eventCount)")
                    .font(DemoTheme.label(12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.75), in: .capsule)
        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5))
        .fixedSize()
        // Track the thumb, but stay inside the rail.
        .offset(x: min(max(0, width * clamped(displayProgress) - 58), width - 116))
        .frame(maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }

    // MARK: - Interaction

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isScrubbing {
                    isScrubbing = true
                    onScrubStateChange(true)
                }
                scrubProgress = clamped(value.location.x / max(width, 1))
            }
            .onEnded { _ in
                onScrub(scrubProgress)
                isScrubbing = false
                onScrubStateChange(false)
            }
    }

    private func clamped(_ value: Double) -> Double { min(1, max(0, value)) }

    static func timecode(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// One rounded bar per density bucket, baseline-aligned.
///
/// A `Shape` rather than a `Canvas` so SwiftUI can skip it entirely when the
/// density array hasn't changed — which is every frame during playback.
private struct EngagementBars: Shape, Equatable {

    let density: [HMDensityBucket]
    /// Quiet stretches still need to read as a track rather than disappear.
    var minimumHeight: CGFloat = 3

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !density.isEmpty else {
            path.addRoundedRect(
                in: CGRect(x: 0, y: rect.maxY - minimumHeight, width: rect.width, height: minimumHeight),
                cornerSize: CGSize(width: minimumHeight / 2, height: minimumHeight / 2)
            )
            return path
        }

        let slot = rect.width / CGFloat(density.count)
        let barWidth = max(1.5, slot * 0.62)
        let radius = barWidth / 2

        for bucket in density {
            let height = minimumHeight + CGFloat(bucket.intensity) * (rect.height - minimumHeight)
            let x = CGFloat(bucket.index) * slot + (slot - barWidth) / 2
            path.addRoundedRect(
                in: CGRect(x: x, y: rect.maxY - height, width: barWidth, height: height),
                cornerSize: CGSize(width: radius, height: radius)
            )
        }
        return path
    }
}
