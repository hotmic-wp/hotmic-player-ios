import SwiftUI

/// Stand-in for B/R's Home tab (demo script 6.3, 6.4), reached from Demo options → Home or the nav
/// bar's Home tab. Each entry closes Home and opens the same player: the "MLB Postseason" playlist,
/// clip 7's card, clip 7's share link and a simulated push alert for clip 7.
struct BRHomeScreen: View {
    let onOpen: (BRDemoEntry) -> Void
    let onClose: () -> Void
    @State private var alertShown = false
    private let playlist = BRDemoContent.catalog.playlist
    private let clip = BRDemoContent.entryClip
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Home").font(.largeTitle.bold()).accessibilityIdentifier("br-home-title")
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close").accessibilityIdentifier("br-home-close")
            }
            .padding(.horizontal, 16).padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Stand-in for your Home tab. Every entry below opens the same player.")
                        .font(.footnote).foregroundStyle(.white.opacity(0.6))
                    playlistCard
                    if let clip {
                        clipCard(clip)
                        entryButtons(clip)
                    }
                }
                .padding(16)
            }
            BRNavBar(selected: .home) { tab in if tab == .watch { onClose() } }
        }
        .overlay(alignment: .top) {
            if alertShown, let clip { alertBanner(clip).transition(.move(edge: .top).combined(with: .opacity)) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .task(id: alertShown) {
            guard alertShown else { return }
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            withAnimation { alertShown = false }
        }
    }
    private var playlistCard: some View {
        Button { onOpen(.playlist) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ForEach(playlist.clips, id: \.key) { clip in
                        BRPoster(url: clip.poster).frame(maxWidth: .infinity).frame(height: 150)
                    }
                }
                Text(playlist.title).font(.title3.bold())
                Text("Playlist · \(playlist.clips.count) clips, then your feed").font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            .padding(12)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(playlist.title)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("br-home-playlist")
    }
    private func clipCard(_ clip: BRDemoClip) -> some View {
        Button { onOpen(.clipCard) } label: {
            HStack(spacing: 12) {
                BRPoster(url: clip.poster).frame(width: 90, height: 160)
                VStack(alignment: .leading, spacing: 6) {
                    Text(clip.title).font(.headline).lineLimit(3)
                    Text(clip.community).font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(clip.title)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("br-home-clip-card")
    }
    private func entryButtons(_ clip: BRDemoClip) -> some View {
        let link = BRDemoContent.shareLink(for: clip)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Other ways into the same clip").font(.subheadline.weight(.semibold))
            Button { onOpen(.shareLink(link)) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Open share link", systemImage: "link")
                    Text(link.absoluteString).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityIdentifier("br-home-share-link")
            Button { withAnimation { alertShown = true } } label: {
                Label("Simulate alert", systemImage: "bell.badge")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityIdentifier("br-home-simulate-alert")
        }
        .buttonStyle(.bordered)
    }
    private func alertBanner(_ clip: BRDemoClip) -> some View {
        Button {
            alertShown = false
            onOpen(.alert)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bell.badge.fill").font(.system(size: 22)).frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("B/R · now").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(clip.title).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    Text("Simulated alert: tap to open").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10).padding(.top, 4)
        .accessibilityIdentifier("br-home-alert-banner")
    }
}
