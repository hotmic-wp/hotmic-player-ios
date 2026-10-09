import SwiftUI
@_spi(Benchmark) import HotMicPlayer

/// Live analytics inspector: the normalised event stream the SDK emits.
struct PlayerEventsList: View {

    let console: HMConsoleSink

    var body: some View {
        List(console.entries) { entry in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.kind.rawValue)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Self.color(for: entry.kind))
                    Spacer()
                    Text(entry.timestamp, format: .dateTime.hour().minute().second())
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(entry.itemTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                let detail = Self.payloadText(entry.event)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        }
        .listStyle(.plain)
        .overlay {
            if console.entries.isEmpty {
                ContentUnavailableView("No events yet", systemImage: "waveform")
            }
        }
    }

    private static func payloadText(_ event: HMPlaybackEvent) -> String {
        var parts: [String] = []
        for (key, value) in event.metrics.sorted(by: { $0.key < $1.key }) {
            parts.append("\(key)=\(String(format: "%.0f", value))")
        }
        for (key, value) in event.properties.sorted(by: { $0.key < $1.key }) where key != "player_key" {
            parts.append("\(key)=\(abbreviated(value))")
        }
        return parts.joined(separator: "  ")
    }

    /// Signed CDN rendition URLs run to several hundred characters and would
    /// otherwise bury every other field in the log.
    private static func abbreviated(_ value: String) -> String {
        guard value.count > 44 else { return value }
        if let url = URL(string: value), let host = url.host() {
            return "\(host)/…/\(url.lastPathComponent)"
        }
        return value.prefix(41) + "…"
    }

    private static func color(for kind: HMPlaybackEvent.Kind) -> Color {
        switch kind {
        case .firstFrame: .green
        case .error, .rebufferStart: DemoTheme.accentHot
        case .preloadStart, .preloadReady, .playerRecycled: DemoTheme.accent
        case .viewStart, .viewEnd: .orange
        default: .primary
        }
    }
}

/// The exact Mux calls the event stream produces.
///
/// This is how the demo proves the Mux story without shipping the Mux SDK — you
/// can read the `monitorAVPlayerLayer` / `videoChangeForPlayer` payloads as they
/// are generated, and see that a recycled pool player fires `videoChange`
/// instead of being torn down.
struct MuxBeaconsList: View {

    let bridge: HMLoggingMuxBridge

    var body: some View {
        List(bridge.beacons) { beacon in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("MUXSDKStats.\(beacon.call)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(DemoTheme.accent)
                    Spacer()
                    Text(beacon.playerName)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                ForEach(beacon.payload.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    HStack(alignment: .top, spacing: 6) {
                        Text(key)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(value)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .bottom) {
            // Worth stating plainly on the one screen where someone might
            // otherwise assume these reached Mux.
            Text("Recorded locally — not transmitted.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(.bar)
        }
        .overlay {
            if bridge.beacons.isEmpty {
                ContentUnavailableView(
                    "No beacons yet",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("Swipe the feed to generate Mux calls.")
                )
            }
        }
    }
}
