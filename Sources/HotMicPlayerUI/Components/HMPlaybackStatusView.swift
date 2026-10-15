#if os(iOS)
import SwiftUI
import HotMicPlayer

/// Buffering and failure status drawn inside the visible video frame, with a tap-to-retry action.
/// Snapshot-driven: only the coarse playback state is read, so live DVR windows behave like VOD.
/// The ready-made overlay shows it when `HMSocialOptions.showsPlaybackStatus` is set; custom overlays place it themselves.
public struct HMPlaybackStatusView: View {
    /// Playback snapshot supplying the coarse lifecycle state.
    public var snapshot: HMPlaybackSnapshot
    /// Retry action for the failed state. `HMPlayer.jump(toID:)` on the failed entry retries its media.
    public var onRetry: (() -> Void)?
    @Environment(\.hmTheme) private var theme
    @State private var spinnerVisible = false
    enum Phase: Equatable {
        case hidden
        case buffering
        case failed
    }
    static func phase(for snapshot: HMPlaybackSnapshot) -> Phase {
        switch snapshot.state {
        case .failed: return .failed
        case .loading, .buffering: return .buffering
        default: return .hidden
        }
    }
    /// Creates this component with host-supplied data and actions.
    public init(snapshot: HMPlaybackSnapshot, onRetry: (() -> Void)? = nil) {
        self.snapshot = snapshot; self.onRetry = onRetry
    }
    /// Renders the component using current observable data and environment theme.
    public var body: some View {
        let phase = Self.phase(for: snapshot)
        ZStack {
            switch phase {
            case .failed:
                HMHitArea {
                    Button(action: { onRetry?() }) {
                        VStack(spacing: 6) {
                            theme.image(for: .retry).font(.system(size: 28, weight: .semibold))
                            Text("Couldn't play this video").font(theme.fonts.emphasis)
                            Text("Tap to retry").font(theme.fonts.caption)
                        }
                        .multilineTextAlignment(.center).minimumScaleFactor(0.7)
                        .foregroundStyle(theme.colors.onVideo).padding(16).frame(minWidth: 44, minHeight: 44)
                        .background(theme.colors.scrim.opacity(0.7), in: RoundedRectangle(cornerRadius: theme.cornerRadius))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Couldn't play this video").accessibilityHint("Retries playback")
                    .accessibilityIdentifier("hm-playback-retry")
                }
            case .buffering:
                ProgressView().progressViewStyle(.circular).controlSize(.large).tint(theme.colors.onVideo)
                    .padding(12).background(theme.colors.scrim.opacity(0.55), in: Circle())
                    .opacity(spinnerVisible ? 1 : 0).allowsHitTesting(false)
                    .accessibilityHidden(!spinnerVisible).accessibilityLabel("Loading")
                    .accessibilityIdentifier("hm-playback-buffering")
            case .hidden:
                EmptyView()
            }
        }
        // A short wall-clock delay hides stalls that resolve before a viewer would notice them.
        .task(id: phase == .buffering) {
            spinnerVisible = false
            guard phase == .buffering else { return }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            spinnerVisible = true
        }
    }
}
#endif
