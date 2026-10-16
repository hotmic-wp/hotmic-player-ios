import SwiftUI

/// A tapped hashtag, as a cover item.
struct BRHashtag: Identifiable, Equatable {
    let tag: String
    var id: String { tag }
    /// `#Lakers`, whether or not the metadata carried the `#`.
    var display: String { tag.hasPrefix("#") ? tag : "#\(tag)" }
}

/// Stand-in for B/R's hashtag discovery page (Vertical Video 1.2): titled with the tag, listing
/// the demo clips that carry it. Close returns to the same clip; the feed pauses while it is open.
struct BRHashtagScreen: View {
    let hashtag: BRHashtag
    let onClose: () -> Void
    private var clips: [BRDemoClip] {
        let catalog = BRDemoContent.catalog
        let bare = hashtag.tag.hasPrefix("#") ? String(hashtag.tag.dropFirst()) : hashtag.tag
        return (catalog.feed + catalog.playlist.clips).filter { clip in
            clip.hashtags.contains { $0.caseInsensitiveCompare(bare) == .orderedSame }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(hashtag.display).font(.largeTitle.bold()).lineLimit(1).minimumScaleFactor(0.6)
                    .accessibilityIdentifier("br-hashtag-title")
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close").accessibilityIdentifier("br-hashtag-close")
            }
            .padding(.horizontal, 16).padding(.top, 8)
            Text("Stand-in for your discovery page. Close it to return to the clip.")
                .font(.footnote).foregroundStyle(.white.opacity(0.6)).padding(.horizontal, 16).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(clips, id: \.key) { clip in
                        HStack(spacing: 12) {
                            BRPoster(url: clip.poster).frame(width: 54, height: 96)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(clip.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                Text(clip.community).font(.caption).foregroundStyle(.white.opacity(0.6))
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    if clips.isEmpty { Text("No demo clips carry this tag.").font(.footnote).foregroundStyle(.white.opacity(0.6)) }
                }
                .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }
}

/// A clip poster for the stand-in screens, cropped to fill its frame.
struct BRPoster: View {
    let url: URL
    var body: some View {
        Color.white.opacity(0.08)
            .overlay {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() } else { Color.clear }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}
