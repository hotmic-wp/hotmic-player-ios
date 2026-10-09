import SwiftUI
@_spi(Benchmark) import HotMicPlayer

/// Runtime tuning surface. Every control maps to a real SDK configuration value
/// so you can change it mid-demo and watch the HUD react.
struct PlayerControlsView: View {

    @Bindable var settings: DemoSettings

    var body: some View {
        Form {
            Section {
                Toggle("Diagnostics HUD", isOn: $settings.showsHUD)
                Toggle("HotMic overlays", isOn: $settings.showsOverlays)
            } footer: {
                Text("Tapping the HUD itself also dismisses it.")
            }

            Section {
                Picker("Preset", selection: $settings.preset) {
                    ForEach(DemoSettings.Preset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.segmented)

                Text(settings.preset.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Playback preset")
            } footer: {
                Text("Swipe between clips after changing this and watch the TTFF readout in the HUD.")
            }

            Section("Preloading") {
                Picker("Warm window", selection: $settings.prefetch) {
                    ForEach(DemoSettings.PrefetchChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .pickerStyle(.segmented)

                Stepper(value: $settings.poolSize, in: 1...8) {
                    LabeledContent("Player pool", value: "\(settings.poolSize) engines")
                }

                Label(
                    "Set the window to Off to feel the un-preloaded startup cost.",
                    systemImage: "lightbulb"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Presentation") {
                Picker("Transition", selection: $settings.transition) {
                    ForEach(HMPageTransition.allCases) { transition in
                        Text(transition.displayName).tag(transition)
                    }
                }
                Toggle("Fill screen (crop to vertical)", isOn: $settings.fillsScreen)
                Toggle("Loop clips", isOn: $settings.loops)
            }

            Section("Build") {
                LabeledContent("SDK", value: HotMicPlayer.version)
            }
        }
    }
}
