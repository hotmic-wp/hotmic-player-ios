import SwiftUI
@_spi(Benchmark) import HotMicPlayer

/// Browse surface. Exists so the demo can *leave* the feed and come back into it
/// at an arbitrary index — which is what proves deep-linking, position restore
/// and warm-window behaviour rather than just "scrolling works".
struct PlaylistView: View {

    let controller: HMPlayer
    @Bindable var settings: DemoSettings
    let onPlay: (Int) -> Void
    let console: HMConsoleSink
    let muxBridge: HMLoggingMuxBridge

    @State private var showsPanel = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if controller.items.isEmpty {
                    loading
                } else {
                    playAllButton
                    list
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .background(background)
        .scrollIndicators(.hidden)
        .task { await controller.start() }
        .demoPanel(
            isPresented: $showsPanel,
            settings: settings,
            console: console,
            muxBridge: muxBridge
        )
    }

    // MARK: - Pieces

    private var background: some View {
        LinearGradient(
            colors: [Color(white: 0.06), .black],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("HotMic")
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                ChromeButton(systemImage: "slider.horizontal.3") { showsPanel = true }
                    .font(.system(size: 16, weight: .semibold))
            }

            Text("Vertical player SDK")
                .font(DemoTheme.label(15, weight: .semibold))
                .foregroundStyle(DemoTheme.accent)

            Text("\(controller.items.count) clips · \(settings.preset.displayName) · preload \(settings.prefetch.displayName)")
                .font(DemoTheme.label(12))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.top, 8)
    }

    private var loading: some View {
        HStack {
            Spacer()
            ProgressView().tint(.white)
            Spacer()
        }
        .padding(.vertical, 60)
    }

    private var playAllButton: some View {
        Button { onPlay(0) } label: {
            HStack(spacing: 10) {
                Image(systemName: "play.fill")
                Text("Play all")
                    .font(DemoTheme.label(16, weight: .bold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    colors: [DemoTheme.accent, DemoTheme.accentHot],
                    startPoint: .leading, endPoint: .trailing
                ),
                in: .rect(cornerRadius: 16)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("play-all")
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Playlist")
                .font(DemoTheme.label(12, weight: .bold))
                .foregroundStyle(.white.opacity(0.45))
                .textCase(.uppercase)
                .kerning(0.8)

            VStack(spacing: 10) {
                ForEach(Array(controller.items.prefix(12).enumerated()), id: \.element.id) { index, item in
                    Button { onPlay(index) } label: {
                        PlaylistRow(
                            index: index,
                            item: item,
                            isCurrent: controller.activeIndex == index,
                            isWarm: controller.snapshot(for: item).state != .idle
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// One clip. The `warm` dot is the interesting part on stage: it lights up for
/// items the pool has already buffered, so you can point at the playlist and
/// say "those three will start instantly".
private struct PlaylistRow: View {

    let index: Int
    let item: HMMediaItem
    let isCurrent: Bool
    let isWarm: Bool

    var body: some View {
        HStack(spacing: 14) {
            poster

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title ?? item.id)
                    .font(DemoTheme.label(15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(item.author ?? "@hotmic")
                    .font(DemoTheme.label(12))
                    .foregroundStyle(.white.opacity(0.55))

                HStack(spacing: 6) {
                    if let duration = item.durationHint {
                        Text(DemoTheme.timecode(duration))
                            .font(DemoTheme.metric(11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    if isWarm {
                        Label("warm", systemImage: "bolt.fill")
                            .font(DemoTheme.label(9, weight: .bold))
                            .foregroundStyle(DemoTheme.accent)
                    }
                }
            }

            Spacer(minLength: 0)

            Image(systemName: isCurrent ? "waveform" : "play.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(isCurrent ? DemoTheme.accent : .white.opacity(0.35))
        }
        .padding(10)
        .background(.white.opacity(isCurrent ? 0.1 : 0.05), in: .rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isCurrent ? DemoTheme.accent.opacity(0.6) : .white.opacity(0.07), lineWidth: 1)
        )
    }

    private var poster: some View {
        Rectangle()
            .fill(.white.opacity(0.06))
            .frame(width: 58, height: 82)
            .overlay {
                if let posterURL = item.posterURL {
                    AsyncImage(url: posterURL) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            Image(systemName: "video.fill")
                                .foregroundStyle(.white.opacity(0.25))
                        }
                    }
                } else {
                    Image(systemName: "video.fill")
                        .foregroundStyle(.white.opacity(0.25))
                }
            }
            .clipShape(.rect(cornerRadius: 10))
            .overlay(alignment: .topLeading) {
                Text("\(index + 1)")
                    .font(DemoTheme.metric(10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: .capsule)
                    .padding(5)
            }
    }
}
