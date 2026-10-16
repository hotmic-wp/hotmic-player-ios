#if os(iOS)
import SwiftUI
import HotMicPlayer

private struct HMSocialStateKey: EnvironmentKey { static let defaultValue: HMSocialState? = nil }
extension EnvironmentValues {
    /// The state of the enclosing `hmSocialPlayback`, for kit chrome drawn above the pages.
    var hmSocialState: HMSocialState? {
        get { self[HMSocialStateKey.self] }
        set { self[HMSocialStateKey.self] = newValue }
    }
}

/// The ready-made companion countdown and band strip, for use inside `hmCompanionOverlay` when
/// composing the feed and overlay yourself.
@MainActor public struct HMCompanionChrome: View {
    private let context: HMCompanionOverlayContext
    private let callbacks: HMSocialCallbacks
    @Environment(\.hmTheme) private var theme
    @Environment(\.hmSocialState) private var state
    @Environment(\.openURL) private var openURL
    private static let pillHeight: CGFloat = 28
    /// Creates the ready-made chrome for a companion overlay context.
    public init(context: HMCompanionOverlayContext, callbacks: HMSocialCallbacks = .init()) {
        self.context = context; self.callbacks = callbacks
    }
    /// Renders the countdown pill during the countdown and the strip over a player-played creative.
    public var body: some View {
        ZStack(alignment: .topLeading) {
            switch context.player.companionState {
            case .countdown: countdown
            case .playing(kind: .player): strip
            case .none, .armed, .playing: EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }
    private var countdown: some View {
        // Leading, just above the current page's progress bar; without a kit state, above the band's dock.
        let frame = context.player.currentItem.flatMap { state?.progressBarFrame(for: $0.id) }
        let bottom = frame?.minY ?? (context.bandFrame.maxY - 8 - 24)
        let leading = frame?.minX ?? (context.bandFrame.minX + 16)
        return TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let remaining = context.player.companionCountdown?.estimatedRemaining(at: ProcessInfo.processInfo.systemUptime) ?? 0
            let seconds = max(1, Int(remaining.rounded(.up)))
            Text("Ad in \(seconds)")
                .font(theme.fonts.caption).foregroundStyle(theme.colors.onVideo)
                .padding(.horizontal, 10).frame(height: Self.pillHeight)
                .background(theme.colors.scrim.opacity(0.85), in: Capsule())
                .accessibilityLabel("Advertisement in \(seconds) seconds")
        }
        .fixedSize()
        .padding(.leading, max(0, leading))
        .padding(.top, max(0, bottom - 6 - Self.pillHeight))
        .allowsHitTesting(false)
        .accessibilityIdentifier("hm-companion-countdown")
    }
    private var strip: some View {
        let player = context.player
        let band = context.bandFrame
        return HStack(spacing: 8) {
            Text(Self.remainingLabel(player.companionProgress))
                .font(theme.fonts.caption).foregroundStyle(theme.colors.onVideo)
                .padding(.horizontal, 8).frame(height: 24)
                .background(theme.colors.scrim.opacity(0.7), in: Capsule())
                .accessibilityLabel(Self.remainingAccessibilityLabel(player.companionProgress))
            Spacer(minLength: 0)
            if let url = context.clickThroughURL {
                Button("Learn more") { (callbacks.companionClickThrough ?? { openURL($0) })(url) }
                    .font(theme.fonts.emphasis).foregroundStyle(theme.colors.onVideo)
                    .padding(.horizontal, 10).frame(minHeight: 44)
                    .accessibilityIdentifier("hm-companion-learn-more")
            }
            Button {
                player.isCompanionMuted.toggle()
            } label: {
                theme.image(for: player.isCompanionMuted ? .muted : .unmuted).font(.system(size: 18)).frame(width: 44, height: 44)
            }
            .foregroundStyle(theme.colors.onVideo)
            .accessibilityLabel(player.isCompanionMuted ? "Unmute ad" : "Mute ad")
            .accessibilityValue(player.isCompanionMuted ? "Muted" : "Audio on")
            .accessibilityIdentifier("hm-companion-mute")
        }
        .buttonStyle(.plain)
        .padding(.leading, 8)
        .frame(width: max(0, band.width), height: 44, alignment: .leading)
        .position(x: band.midX, y: band.minY + 22)
    }
    static func remainingLabel(_ progress: HMAdProgress) -> String {
        guard progress.duration > 0 else { return "Ad" }
        let remaining = Int(max(0, progress.duration - progress.elapsed).rounded(.up))
        return String(format: "Ad · %d:%02d remaining", remaining / 60, remaining % 60)
    }
    static func remainingAccessibilityLabel(_ progress: HMAdProgress) -> String {
        guard progress.duration > 0 else { return "Advertisement" }
        let remaining = Int(max(0, progress.duration - progress.elapsed).rounded(.up))
        return "Advertisement, \(remaining) seconds remaining"
    }
}
#endif
