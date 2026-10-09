import SwiftUI
@_spi(Benchmark) import HotMicPlayer

/// The single panel behind the one toolbar button.
///
/// Player tuning and the two analytics views used to be three separate controls
/// in the feed chrome, which is three things competing with the video for a
/// demo surface that should be almost entirely video.
struct DemoPanelView: View {

    enum Tab: String, CaseIterable, Identifiable {
        case player = "Player"
        case events = "Events"
        case mux = "Mux"
        var id: String { rawValue }
    }

    @Bindable var settings: DemoSettings
    let console: HMConsoleSink
    let muxBridge: HMLoggingMuxBridge
    let onDismiss: () -> Void

    @State private var tab: Tab = .player

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)

                switch tab {
                case .player: PlayerControlsView(settings: settings)
                case .events: PlayerEventsList(console: console)
                case .mux: MuxBeaconsList(bridge: muxBridge)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if tab == .events {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Clear") { console.clear() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                }
            }
        }
    }
}

extension View {
    /// Presents the demo panel from *this* view.
    ///
    /// Attached per screen rather than once at the root on purpose: the feed is
    /// a full-screen cover, and a sheet presented from the view behind a cover
    /// never appears.
    func demoPanel(
        isPresented: Binding<Bool>,
        settings: DemoSettings,
        console: HMConsoleSink,
        muxBridge: HMLoggingMuxBridge
    ) -> some View {
        sheet(isPresented: isPresented) {
            DemoPanelView(settings: settings, console: console, muxBridge: muxBridge) {
                isPresented.wrappedValue = false
            }
            .presentationDetents([.medium, .large])
            // Playback keeps running behind the sheet, so an opaque backing is
            // what keeps the content readable.
            .presentationBackground(Color(white: 0.09))
        }
    }
}
