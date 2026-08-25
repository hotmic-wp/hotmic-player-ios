import SwiftUI
import HotMicPlayer

/// Trailing action column. Mirrors the `leadingRail`/`trailingRail` slot idea
/// from the architecture notes without building the full plugin registry yet.
struct ActionRailView: View {

    let isMuted: Bool
    let onReact: (String) -> Void
    let onMuteToggle: () -> Void

    /// What a tap sends. Bumped on each tap so the symbol effect retriggers.
    @State private var reactionCount = 0

    var body: some View {
        VStack(spacing: 20) {
            Button {
                reactionCount += 1
                onReact("🔥")
            } label: {
                railButton(system: "flame.fill", tint: DemoTheme.accentHot)
            }
            .symbolEffect(.bounce, value: reactionCount)

            railButton(system: "bubble.right.fill", tint: .white)

            Button(action: onMuteToggle) {
                railButton(
                    system: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    tint: isMuted ? DemoTheme.accentHot : .white
                )
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private func railButton(system: String, tint: Color) -> some View {
        Image(systemName: system)
            .font(.system(size: 26))
            .foregroundStyle(tint)
            .videoLegible()
            .frame(width: 56, height: 48)
            .contentShape(.rect)
    }
}
