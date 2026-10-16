import SwiftUI
import HotMicPlayer
import HotMicPlayerUI

/// B/R's metadata block through the kit's `metadata` slot: community, title, the audience badge,
/// then a two-line description that expands when tapped, and one row of hashtags. Dropping the
/// kit's separate "Show more" row keeps the block short, so the rail above it clears the header
/// on long-description clips. Accessibility text sizes fall back to the kit's own view.
struct BRMetadata: View {
    let context: HMSocialMetadataContext
    @Environment(\.hmTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        if dynamicType.isAccessibilitySize {
            HMMetadataView(content: context.content, onExpand: context.expand, onHashtag: context.hashtagTapped)
        } else {
            compact
        }
    }

    private var content: HMSocialContent { context.content }

    private var compact: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let community = content.community {
                Text(community).font(theme.fonts.caption).foregroundStyle(theme.colors.onVideoSecondary)
            }
            Text(content.title).font(theme.fonts.headline).lineLimit(2)
            HMAudienceBadge(audienceCount: content.audienceCount, viewCount: content.viewCount)
            if !content.description.isEmpty {
                Button(action: context.expand) {
                    Text(content.description).font(theme.fonts.body).lineLimit(2)
                        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the full description")
                .accessibilityIdentifier("hm-description-toggle")
            }
            if !content.hashtags.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { tags(content.hashtags) }
                    HStack(spacing: 14) { tags(Array(content.hashtags.prefix(2))) }
                    HStack(spacing: 14) { tags(Array(content.hashtags.prefix(1))) }
                }
            }
        }
        .foregroundStyle(theme.colors.onVideo)
        .shadow(color: BRTheme.videoShadow, radius: 4, y: 1)
    }

    private func tags(_ hashtags: [String]) -> some View {
        ForEach(Array(hashtags.enumerated()), id: \.offset) { _, tag in
            Button(tag.hasPrefix("#") ? tag : "#" + tag) { context.hashtagTapped(tag) }
                .font(theme.fonts.emphasis).frame(minHeight: 36).fixedSize()
                .accessibilityLabel("Hashtag \(tag)")
        }
    }
}
