import SwiftUI
@_spi(Benchmark) import HotMicPlayer

/// Everything drawn on top of one feed cell.
///
/// Composed from independent pieces that each claim a region — the informal
/// version of the `OverlaySlot` idea. Nothing here reaches into the player; it
/// reads a `HMPlaybackSnapshot` and a timeline, and calls back for actions.
struct FeedOverlayView: View {

    let item: HMMediaItem
    let snapshot: HMPlaybackSnapshot
    let timeline: any HMStreamTimeline
    let isActive: Bool
    let settings: DemoSettings
    let poolBusy: Int
    let poolSize: Int
    let isMuted: Bool

    let onTogglePlayPause: () -> Void
    let onToggleMute: () -> Void
    let onSeek: (Double) -> Void

    @Environment(\.hmFeedSafeArea) private var safeArea

    @State private var isScrubbing = false
    @State private var showPlayGlyph = false
    @State private var echo: ReactionStreamView.Echo?
    @State private var echoCount = 0

    /// Leaves room for the app's own floating chrome, which sits above the feed.
    private var topInset: CGFloat { safeArea.top + 52 }
    private var bottomInset: CGFloat { safeArea.bottom + 14 }

    /// Seekable span, which is what the scrubber measures itself against.
    /// Equals the asset duration on VOD and the DVR window on live.
    private var duration: TimeInterval {
        snapshot.seekableDuration > 0 ? snapshot.seekableDuration : (item.durationHint ?? 1)
    }

    /// Prefer what the player actually reports over what the feed API claimed.
    private var isLive: Bool { snapshot.isLive }

    /// Where the playhead sits on the *engagement* timeline.
    ///
    /// Wrapped rather than clamped. A looping clip replays its own timeline, and
    /// a live stream — whose media clock runs indefinitely past the mock
    /// timeline's span — keeps receiving engagement instead of falling off the
    /// end and going silent after twenty seconds.
    private var timelineOffset: TimeInterval {
        let span = timeline.duration
        guard span > 0, snapshot.currentTime.isFinite else { return 0 }
        return snapshot.currentTime.truncatingRemainder(dividingBy: span)
    }

    var body: some View {
        ZStack {
            // Keeps captions and chat readable over bright video without
            // dimming the whole frame.
            LinearGradient(
                colors: [.clear, .black.opacity(0.5)],
                startPoint: .center,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            tapLayer

            if settings.showsOverlays && isActive {
                ReactionStreamView(
                    timeline: timeline,
                    offset: timelineOffset,
                    isPlaying: snapshot.state == .playing,
                    echo: echo
                )
            }

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomStack
            }
            .padding(.horizontal, 16)
            .padding(.top, topInset)
            .padding(.bottom, bottomInset)

            if settings.showsHUD && isActive {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        // Tapping the panel dismisses it — the same instinct
                        // most people have before they find the toolbar toggle.
                        DebugHUDView(
                            snapshot: snapshot,
                            poolBusy: poolBusy,
                            poolSize: poolSize,
                            prefetchLabel: settings.prefetch.displayName
                        )
                        .contentShape(.rect)
                        .onTapGesture { settings.showsHUD = false }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, topInset + 40)
                .transition(.opacity)
            }

            bufferingIndicator
            playGlyph
        }
    }

    /// Weight of one deliberate tap.
    ///
    /// Heavier than a single ambient reaction on purpose: the rail is scaled for
    /// crowd volume, so a weight of one would be invisible and the tap would
    /// read as doing nothing. At this weight one tap nudges the bar and a few
    /// taps build a peak that starts emitting on replay.
    private static let viewerReactionWeight = 4

    /// A viewer's reaction goes onto the timeline itself, so it shows up on the
    /// waveform, survives a scrub-back, and behaves exactly like an event that
    /// arrived over the wire. The echo is separate: your own tap should animate
    /// immediately even during a stretch too quiet to emit crowd reactions.
    private func react(with emoji: String) {
        timeline.append(
            HMTimelineEvent(
                offset: timelineOffset,
                kind: .reaction,
                emoji: emoji,
                magnitude: Self.viewerReactionWeight
            )
        )
        echoCount += 1
        echo = ReactionStreamView.Echo(id: echoCount, emoji: emoji)
    }

    // MARK: - Regions

    private var tapLayer: some View {
        Color.clear
            .contentShape(.rect)
            .onTapGesture {
                onTogglePlayPause()
                showPlayGlyph = true
                Task {
                    try? await Task.sleep(for: .milliseconds(550))
                    showPlayGlyph = false
                }
            }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            if isLive {
                Label("LIVE", systemImage: "dot.radiowaves.left.and.right")
                    .font(DemoTheme.label(11, weight: .black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(DemoTheme.live, in: .capsule)
            }
            Spacer()
        }
        .videoLegible()
    }

    private var bottomStack: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    if settings.showsOverlays {
                        ChatRailView(timeline: timeline, offset: timelineOffset)
                    }
                    Text(item.author ?? "@hotmic")
                        .font(DemoTheme.label(14, weight: .bold))
                        .foregroundStyle(.white)
                    Text(item.title ?? item.id)
                        .font(DemoTheme.label(13))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(2)
                }
                .videoLegible()

                Spacer(minLength: 0)

                if settings.showsOverlays {
                    ActionRailView(isMuted: isMuted, onReact: react(with:), onMuteToggle: onToggleMute)
                }
            }

            EmojiScrubberView(
                progress: snapshot.progress,
                bufferedProgress: duration > 0
                    ? min(1, (snapshot.progress * duration + snapshot.bufferedAhead) / duration)
                    : 0,
                density: settings.showsOverlays ? timeline.density : [],
                markers: settings.showsOverlays ? timeline.markers : [],
                duration: duration,
                isLive: isLive,
                onScrub: onSeek,
                onScrubStateChange: { isScrubbing = $0 }
            )
        }
    }

    @ViewBuilder
    private var bufferingIndicator: some View {
        if isActive && (snapshot.state == .buffering || snapshot.state == .loading) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .scaleEffect(1.2)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var playGlyph: some View {
        if showPlayGlyph {
            Image(systemName: snapshot.state == .playing ? "play.fill" : "pause.fill")
                .font(.system(size: 54))
                .foregroundStyle(.white.opacity(0.85))
                .shadow(radius: 12)
                .transition(.scale(scale: 1.4).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }
}
