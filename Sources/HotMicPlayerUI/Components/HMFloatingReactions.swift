#if os(iOS)
import SwiftUI
import HotMicPlayer

/// Reactions that rise up the trailing edge as the playhead crosses them.
///
/// Driven by the timeline around the playhead, so they replay identically after
/// a scrub-back. Density-gated: nothing flies while the waveform under the
/// playhead is below `quietFloor`, and the rate ramps with the waveform above it,
/// so emoji appear exactly where the scrubber shows something happening. The
/// viewer's own reaction (`HMEngagement.lastReactionEcho`) always animates.
///
/// Place it full-bleed over the video; it never takes touches. With Reduce Motion
/// on, emoji fade in place instead of rising, and ambient crowd reactions are off.
public struct HMFloatingReactions: View {

    private let engagement: HMEngagement
    private let mediaTime: TimeInterval
    private let isPlaying: Bool
    private let quietFloor: Double
    private let trailingInset: CGFloat
    private let launchHeight: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Reaction weight that buys one on-screen emoji.
    private static let weightPerFloater: Double = 12
    /// Ceiling per tick, so a stall can't dump a burst at once.
    private static let maximumPerTick = 4
    private static let maximumAlive = 24

    @State private var live: [Floater] = []
    @State private var lastSampledTime: TimeInterval = -1
    @State private var pendingWeight: Double = 0
    @State private var nextFloaterNumber = 0

    /// Creates the reaction stream.
    /// - Parameters:
    ///   - isPlaying: Ambient reactions only emit during playback.
    ///   - quietFloor: Waveform height (0...1) below which ambient reactions don't fly.
    ///   - trailingInset: Distance of the launch column from the trailing edge.
    ///   - launchHeight: Launch point as a fraction of the height, from the top.
    public init(engagement: HMEngagement, mediaTime: TimeInterval, isPlaying: Bool, quietFloor: Double = 0.45,
                trailingInset: CGFloat = 34, launchHeight: Double = 0.6) {
        self.engagement = engagement
        self.mediaTime = mediaTime
        self.isPlaying = isPlaying
        self.quietFloor = min(0.99, max(0, quietFloor))
        self.trailingInset = trailingInset
        self.launchHeight = launchHeight
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(live) { floater in
                    HMFloaterView(floater: floater, height: proxy.size.height, rises: !reduceMotion) {
                        live.removeAll { $0.id == floater.id }
                    }
                    .position(x: proxy.size.width - trailingInset - floater.lane * 22,
                              y: proxy.size.height * launchHeight)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: mediaTime) { _, newValue in sample(at: newValue) }
        .onChange(of: engagement.lastReactionEcho) { _, echo in
            guard let echo else { return }
            emit(count: reduceMotion ? 1 : 3, emoji: echo.emoji, magnitude: 3, seed: echo.id)
        }
    }

    /// Pull the reactions in the slice of time just crossed.
    private func sample(at time: TimeInterval) {
        let offset = engagement.timelineOffset(forMediaTime: time)
        defer { lastSampledTime = offset }
        // A seek jumps the clock: drop the backlog rather than flooding the screen.
        guard !reduceMotion, isPlaying, lastSampledTime >= 0, offset > lastSampledTime, offset - lastSampledTime < 1.0 else {
            pendingWeight = 0
            return
        }
        // Ramp rather than switch, so the flow builds into a peak.
        let gain = (engagement.intensity(at: offset) - quietFloor) / (1 - quietFloor)
        guard gain > 0 else { pendingWeight = 0; return }
        let reactions = engagement.reactions(in: lastSampledTime...offset)
        guard !reactions.isEmpty else { return }
        pendingWeight += reactions.reduce(0) { $0 + Double($1.magnitude) } * gain

        var emitted = 0
        while pendingWeight >= Self.weightPerFloater, emitted < Self.maximumPerTick {
            pendingWeight -= Self.weightPerFloater
            let source = reactions[emitted % reactions.count]
            emit(count: 1, emoji: source.emoji ?? "🔥", magnitude: source.magnitude,
                 seed: Int(HMFormat.stableHash(source.id) % 3))
            emitted += 1
        }
        // Never bank more than a tick's worth, or a busy stretch keeps emitting after the peak.
        pendingWeight = min(pendingWeight, Self.weightPerFloater)
    }

    private func emit(count: Int, emoji: String, magnitude: Int, seed: Int) {
        for index in 0..<count {
            nextFloaterNumber += 1
            live.append(Floater(id: nextFloaterNumber, emoji: emoji, lane: Double((seed + index) % 3),
                                scale: 0.8 + Double(min(magnitude, 4)) * 0.12))
        }
        if live.count > Self.maximumAlive { live.removeFirst(live.count - Self.maximumAlive) }
    }

    struct Floater: Identifiable {
        let id: Int
        let emoji: String
        let lane: Double
        let scale: Double
    }
}

/// One emoji, rising and fading, then removing itself.
private struct HMFloaterView: View {
    let floater: HMFloatingReactions.Floater
    let height: CGFloat
    let rises: Bool
    let onFinished: () -> Void

    @State private var progress: CGFloat = 0
    @ScaledMetric(relativeTo: .title) private var size: CGFloat = 26

    var body: some View {
        Text(floater.emoji)
            .font(.system(size: size * floater.scale))
            .modifier(HMRiseEffect(progress: progress, rises: rises, lane: floater.lane, travel: min(height * 0.42, 260)))
            .onAppear {
                let duration = rises ? 2.2 : 1.2
                withAnimation(rises ? .easeOut(duration: duration) : .linear(duration: duration)) { progress = 1 }
                Task { try? await Task.sleep(for: .seconds(duration)); onFinished() }
            }
    }
}

/// Evaluated every frame, so the sway and fade curves are real curves rather
/// than a straight interpolation between their start and end values.
private struct HMRiseEffect: ViewModifier, Animatable {
    var progress: CGFloat
    let rises: Bool
    let lane: Double
    let travel: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        if rises {
            content
                .offset(x: sin(progress * 5 + lane * 2) * 10, y: -progress * travel)
                .scaleEffect(0.7 + min(progress * 4, 1) * 0.3)
                .opacity(1 - Double(progress * progress))
        } else {
            // Reduce Motion: no travel, just a short fade in and out in place.
            content.opacity(Double(progress < 0.3 ? progress / 0.3 : (1 - progress) / 0.7))
        }
    }
}
#endif
