import SwiftUI
@_spi(Benchmark) import HotMicPlayer

/// Floating reactions that rise off the action rail.
///
/// Driven by the timeline window around the playhead, so they replay identically
/// on a scrub-back — the whole point of `(clock, timeline)`. The emission rate is
/// proportional to how much is happening at that moment: a trickle during
/// ordinary chatter, a flood when the playhead reaches a peak.
struct ReactionStreamView: View {

    let timeline: any HMStreamTimeline
    /// Playhead position on the *engagement* timeline, not the media clock.
    let offset: TimeInterval
    let isPlaying: Bool
    /// A reaction the viewer just sent. Always animates, however quiet the
    /// timeline is at that moment — your own tap should never feel ignored.
    var echo: Echo?

    struct Echo: Equatable {
        let id: Int
        let emoji: String
    }

    /// Reaction weight that buys one on-screen emoji. Rendering every event
    /// would be both unreadable and pointless — what matters is that the rate
    /// tracks the timeline.
    private static let weightPerFloater: Double = 12
    /// Waveform height below which nothing flies.
    ///
    /// Ambient reactions exist to give the rail a continuous waveform, but they
    /// are not *moments*. Emitting for them puts emoji on screen while the rail
    /// looks flat, which reads as the two being unrelated. Gating on the same
    /// density array the bars are drawn from means emoji appear exactly where
    /// you can see something happening.
    private static let quietFloor: Double = 0.45
    /// Ceiling per tick, so a seek or a stall can't dump a burst all at once.
    private static let maximumPerTick = 4
    private static let maximumAlive = 24

    @State private var live: [Floater] = []
    @State private var lastSampledTime: TimeInterval = -1
    @State private var pendingWeight: Double = 0
    @State private var nextFloaterNumber = 0

    struct Floater: Identifiable {
        let id: Int
        let emoji: String
        let lane: Double
        let scale: Double
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(live) { floater in
                    FloaterView(floater: floater, height: proxy.size.height)
                        // Launch from the action rail rather than the very
                        // bottom of the cell, which would put them on top of
                        // the scrubber.
                        .position(
                            x: proxy.size.width - 26 - floater.lane * 46,
                            y: proxy.size.height * 0.62
                        )
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: offset) { _, newValue in sample(at: newValue) }
        .onChange(of: echo) { _, newValue in
            guard let newValue else { return }
            emit(count: 3, emoji: newValue.emoji, magnitude: 3, seed: newValue.id)
        }
    }

    /// Pull the reactions that fall in the slice of time we just crossed.
    private func sample(at time: TimeInterval) {
        defer { lastSampledTime = time }

        // A seek jumps the clock. Drop the backlog rather than dumping a few
        // hundred emoji on screen at the new position.
        guard isPlaying, lastSampledTime >= 0, time > lastSampledTime, time - lastSampledTime < 1.0 else {
            pendingWeight = 0
            return
        }

        // Ramp rather than switch, so the flow builds into a peak instead of
        // popping on at its edge.
        let gain = (localIntensity(at: time) - Self.quietFloor) / (1 - Self.quietFloor)
        guard gain > 0 else { pendingWeight = 0; return }

        let reactions = timeline.events(in: lastSampledTime...time).filter { $0.kind == .reaction }
        guard !reactions.isEmpty else { return }

        pendingWeight += reactions.reduce(0) { $0 + Double($1.magnitude) } * gain

        var emitted = 0
        while pendingWeight >= Self.weightPerFloater, emitted < Self.maximumPerTick {
            pendingWeight -= Self.weightPerFloater
            let source = reactions[emitted % reactions.count]
            emit(
                count: 1,
                emoji: source.emoji ?? "🔥",
                magnitude: source.magnitude,
                seed: Self.lane(for: source.id)
            )
            emitted += 1
        }

        // Never bank more than a tick's worth, or a busy stretch keeps emitting
        // after the peak has passed.
        pendingWeight = min(pendingWeight, Self.weightPerFloater)
    }

    private func emit(count: Int, emoji: String, magnitude: Int, seed: Int) {
        for index in 0..<count {
            nextFloaterNumber += 1
            live.append(
                Floater(
                    id: nextFloaterNumber,
                    emoji: emoji,
                    lane: Double((seed + index) % 3) * 0.6,
                    scale: 0.8 + Double(min(magnitude, 4)) * 0.12
                )
            )
        }
        if live.count > Self.maximumAlive { live.removeFirst(live.count - Self.maximumAlive) }
    }

    /// Height of the waveform bar under the playhead. The density array is
    /// uniformly spaced, so this indexes directly rather than searching.
    private func localIntensity(at offset: TimeInterval) -> Double {
        let density = timeline.density
        guard !density.isEmpty, timeline.duration > 0 else { return 0 }
        let position = min(0.999, max(0, offset / timeline.duration))
        return density[Int(position * Double(density.count))].intensity
    }

    /// Stable across runs, unlike `hashValue`, which is seeded per process.
    private static func lane(for id: String) -> Int {
        var hash: UInt64 = 5381
        for byte in id.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return Int(hash % 3)
    }
}

/// One emoji, rising and fading. Self-removing so the parent holds no timers.
private struct FloaterView: View {
    let floater: ReactionStreamView.Floater
    let height: CGFloat

    @State private var progress: CGFloat = 0

    var body: some View {
        Text(floater.emoji)
            .font(.system(size: 26 * floater.scale))
            .offset(
                x: sin(progress * 6) * 14,
                y: -progress * min(height * 0.45, 240)
            )
            .opacity(1 - Double(progress) * Double(progress))
            .onAppear {
                withAnimation(.easeOut(duration: 2.2)) { progress = 1 }
            }
    }
}
