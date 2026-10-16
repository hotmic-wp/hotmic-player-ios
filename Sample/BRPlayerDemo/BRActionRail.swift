import SwiftUI
import HotMicPlayer
import HotMicPlayerUI

/// B/R's right rail through the kit's `actionRail` slot: the creator's avatar with a follow "+",
/// then Fire, Comment and Share with their counts underneath, white on the video with no box.
/// The theme can't add the avatar, so this slot replaces the kit rail; every action still goes
/// through the kit's context, so the Fire burst, the sheet and Share behave exactly as before.
struct BRActionRail: View {
    let item: HMMediaItem
    let context: HMSocialRailContext
    @Environment(\.hmTheme) private var theme
    @ScaledMetric(relativeTo: .title2) private var iconSize: CGFloat = 28

    var body: some View {
        VStack(spacing: theme.railSpacing) {
            if let creator = BRDemoContent.catalog.clip(forItemID: item.id)?.creator {
                BRCreatorAvatar(handle: creator.handle, name: creator.name)
            }
            if context.canFire {
                button(.fire, label: "Fire", count: context.content.fireCount, action: context.fire)
                    .foregroundStyle(context.content.isReacted ? theme.colors.accentSecondary : theme.colors.onVideo)
                    .accessibilityValue((context.content.isReacted ? "reacted" : "not reacted")
                        + (context.content.fireCount.map { ", \($0) reactions" } ?? ""))
                    .accessibilityIdentifier("hm-fire")
            }
            button(.comment, label: "Comment", count: context.content.commentCount, action: context.openComments)
                .accessibilityIdentifier("hm-comments")
            button(.share, label: "Share", count: context.content.shareCount, action: context.share)
                .accessibilityIdentifier("hm-share")
        }
        .foregroundStyle(theme.colors.onVideo)
        .sensoryFeedback(.impact(weight: .light), trigger: context.fireEvent)
    }

    private func button(_ icon: HMTheme.Icon, label: String, count: Int?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                theme.image(for: icon)
                    .symbolVariant(icon == .fire && context.content.isReacted ? .fill : .none)
                    .font(.system(size: min(40, iconSize), weight: .regular))
                    .background(GeometryReader { geometry in
                        if icon == .fire {
                            // The kit's burst flies to this frame, in the overlay's named space.
                            Color.clear.onChange(of: geometry.frame(in: .named("hm-social-overlay")), initial: true) { _, frame in
                                context.fireFrameChanged(frame)
                            }
                        }
                    })
                if let count {
                    Text(HMCountFormatter().string(from: count)).font(theme.fonts.caption.monospacedDigit())
                        .contentTransition(.numericText(value: Double(count)))
                }
            }
            .shadow(color: BRTheme.videoShadow, radius: 4, y: 1)
            .frame(minWidth: 52, minHeight: 52)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
