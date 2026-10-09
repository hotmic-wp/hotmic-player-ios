#if os(iOS)
import SwiftUI
import HotMicPlayer

/// A scrubber drawn as the item's engagement waveform, with tappable peaks.
///
/// Bars fill as you watch. Emoji over the busiest moments are buttons: tap one to
/// jump there. Drag anywhere on the bars to scrub; the rail grows and a timecode
/// with what happened at that point follows the thumb. VoiceOver adjusts it in
/// 5% steps, and each peak is its own button.
///
/// Built so playback does not redraw it: the bars are a `Shape` that depends
/// only on the density array, drawn twice and revealed by a mask whose width is
/// the only thing a time tick changes.
public struct HMEngagementScrubber: View {

    private let engagement: HMEngagement
    private let snapshot: HMPlaybackSnapshot
    private let onSeek: (TimeInterval) -> Void
    private let onScrubbingChanged: ((Bool) -> Void)?

    @Environment(\.hmTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isScrubbing = false
    @State private var scrubProgress: Double = 0
    @State private var seekCount = 0

    /// Creates a scrubber for one item.
    /// - Parameters:
    ///   - onSeek: Receives a media time in seconds, from a scrub or a tapped peak.
    ///   - onScrubbingChanged: Called when a drag starts and ends, for example to defer feed gestures.
    public init(engagement: HMEngagement, snapshot: HMPlaybackSnapshot, onSeek: @escaping (TimeInterval) -> Void,
                onScrubbingChanged: ((Bool) -> Void)? = nil) {
        self.engagement = engagement
        self.snapshot = snapshot
        self.onSeek = onSeek
        self.onScrubbingChanged = onScrubbingChanged
    }

    /// Seekable span; the timeline's own duration until the asset reports one.
    private var duration: TimeInterval {
        if snapshot.seekableDuration > 0 { return snapshot.seekableDuration }
        return engagement.duration
    }
    private var progress: Double {
        snapshot.seekableDuration > 0 ? snapshot.progress : clamped(snapshot.currentTime / max(duration, 0.001))
    }
    private var displayProgress: Double { isScrubbing ? scrubProgress : progress }
    private var bufferedProgress: Double {
        duration > 0 ? clamped((progress * duration + snapshot.bufferedAhead) / duration) : 0
    }
    private var barHeight: CGFloat { isScrubbing ? 38 : 22 }

    public var body: some View {
        let density = engagement.density
        let markers = engagement.markers

        VStack(spacing: 2) {
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    if isScrubbing { readout(width: proxy.size.width, density: density) }
                    markerRow(markers, width: proxy.size.width)
                }
            }
            .frame(height: isScrubbing ? 58 : 30)

            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .bottomLeading) {
                    waveform(density, width: width)
                    playhead(width: width)
                }
                .frame(width: width, height: proxy.size.height, alignment: .bottom)
                .contentShape(.rect)
                .gesture(scrubGesture(width: width))
            }
            .frame(height: 44)
            .accessibilityElement()
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(HMFormat.spoken(displayProgress * duration)) of \(HMFormat.spoken(duration))")
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 0.05 : -0.05
                seek(toProgress: clamped(progress + step))
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: isScrubbing)
        .sensoryFeedback(.selection, trigger: seekCount)
    }

    // MARK: - Layers

    private func waveform(_ density: [HMDensityBucket], width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            HMEngagementBars(density: density).fill(theme.colors.track)
            HMEngagementBars(density: density)
                .fill(theme.colors.onVideo.opacity(0.14))
                .mask(alignment: .leading) { Rectangle().frame(width: width * bufferedProgress) }
            HMEngagementBars(density: density)
                .fill(LinearGradient(colors: [theme.colors.accent, theme.colors.accentSecondary],
                                     startPoint: .leading, endPoint: .trailing))
                .mask(alignment: .leading) { Rectangle().frame(width: width * displayProgress) }
                .shadow(color: theme.colors.accent.opacity(0.45), radius: 5, y: 1)
        }
        .frame(height: barHeight)
    }

    private func markerRow(_ markers: [HMTimelineMarker], width: CGFloat) -> some View {
        ForEach(markers) { marker in
            Button {
                seek(toProgress: marker.position)
            } label: {
                Text(marker.emoji)
                    .font(isScrubbing ? .title3 : .callout)
                    .shadow(color: .black.opacity(0.6), radius: 3)
                    .frame(width: 44, height: 30)
                    .contentShape(.rect)
            }
            .buttonStyle(HMMarkerButtonStyle())
            .position(x: min(max(22, marker.position * width), width - 22), y: isScrubbing ? 44 : 15)
            .accessibilityLabel("Moment at \(HMFormat.spoken(marker.position * duration)), \(marker.emoji), \(marker.count) reactions")
            .accessibilityHint("Jumps to this moment")
        }
    }

    private func playhead(width: CGFloat) -> some View {
        Capsule()
            .fill(theme.colors.onVideo)
            .frame(width: 3, height: barHeight + 8)
            .shadow(color: .black.opacity(0.35), radius: 2)
            .overlay(alignment: .top) {
                Circle()
                    .fill(theme.colors.onVideo)
                    .frame(width: isScrubbing ? 12 : 7, height: isScrubbing ? 12 : 7)
                    .offset(y: -4)
            }
            .offset(x: width * displayProgress - 1.5, y: 4)
            .allowsHitTesting(false)
    }

    /// Timecode that tracks the thumb, with a summary of what happened there.
    private func readout(width: CGFloat, density: [HMDensityBucket]) -> some View {
        let nearby = density.first { abs($0.position - displayProgress) < 0.02 }
        return HStack(spacing: 6) {
            Text("\(HMFormat.timecode(displayProgress * duration)) / \(HMFormat.timecode(duration))")
                .font(theme.fonts.metric)
            if let nearby, nearby.eventCount > 0 {
                Text("\(nearby.dominantEmoji ?? "💬") \(HMFormat.compact(nearby.eventCount))")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.onVideoSecondary)
            }
        }
        .foregroundStyle(theme.colors.onVideo)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.7), in: .capsule)
        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
        .fixedSize()
        .alignmentGuide(.leading) { dimensions in
            -min(max(0, width * displayProgress - dimensions.width / 2), width - dimensions.width)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Interaction

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isScrubbing {
                    isScrubbing = true
                    onScrubbingChanged?(true)
                }
                scrubProgress = clamped(value.location.x / max(width, 1))
            }
            .onEnded { _ in
                seek(toProgress: scrubProgress)
                isScrubbing = false
                onScrubbingChanged?(false)
            }
    }

    private func seek(toProgress target: Double) {
        seekCount += 1
        onSeek(snapshot.seekableStart + clamped(target) * duration)
    }

    private func clamped(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
}

private struct HMMarkerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.35 : 1)
            .animation(.spring(duration: 0.2, bounce: 0.4), value: configuration.isPressed)
    }
}

/// One rounded bar per density bucket, baseline-aligned. A `Shape` rather than a
/// `Canvas` so SwiftUI skips it entirely while the density array is unchanged.
struct HMEngagementBars: Shape, Equatable {
    let density: [HMDensityBucket]
    /// Quiet stretches still read as a track rather than disappearing.
    var minimumHeight: CGFloat = 3

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !density.isEmpty else {
            path.addRoundedRect(in: CGRect(x: 0, y: rect.maxY - minimumHeight, width: rect.width, height: minimumHeight),
                                cornerSize: CGSize(width: minimumHeight / 2, height: minimumHeight / 2))
            return path
        }
        let slot = rect.width / CGFloat(density.count)
        let barWidth = max(1.5, slot * 0.62)
        let radius = barWidth / 2
        for bucket in density {
            let height = minimumHeight + CGFloat(bucket.intensity) * (rect.height - minimumHeight)
            let x = CGFloat(bucket.index) * slot + (slot - barWidth) / 2
            path.addRoundedRect(in: CGRect(x: x, y: rect.maxY - height, width: barWidth, height: height),
                                cornerSize: CGSize(width: radius, height: radius))
        }
        return path
    }
}
#endif
