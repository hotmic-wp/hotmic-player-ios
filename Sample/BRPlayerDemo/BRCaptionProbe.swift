import AVFoundation
import HotMicPlayer
import SwiftUI

/// THROWAWAY (ticket 21 proof build, reverted before the PR): what AVFoundation offers as legible
/// media-selection options for every feed clip, next to what the SDK reports for the current one.
struct BRCaptionProbeSheet: View {
    let player: HMPlayer
    @State private var report = "Probing…"
    var body: some View {
        NavigationStack {
            ScrollView {
                Text(report).font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            .navigationTitle("Caption probe")
        }
        .task {
            let items = player.items, current = player.currentItem?.id, languages = player.availableCaptionLanguages
            report = await BRCaptionProbe.report(items: items, current: current, sdkLanguages: languages)
        }
    }
}

enum BRCaptionProbe {
    static func report(items: [HMMediaItem], current: String?, sdkLanguages: [String]) async -> String {
        var lines = ["current=\(current ?? "-")", "sdk.availableCaptionLanguages=\(sdkLanguages)", ""]
        for item in items {
            guard let url = item.url else { continue }
            let slot = item.metadata["br.slot"] ?? item.id
            lines.append("[\(slot)] \(url.pathComponents.dropFirst(2).joined(separator: "/")) sidecars=\(item.captionSources.keys.sorted())")
            let asset = AVURLAsset(url: url)
            do {
                let characteristics = try await asset.load(.availableMediaCharacteristicsWithMediaSelectionOptions)
                lines.append("  characteristics=\(characteristics.map(\.rawValue))")
                guard let group = try await asset.loadMediaSelectionGroup(for: .legible) else {
                    lines.append("  legible group: nil"); lines.append(""); continue
                }
                lines.append("  legible group: \(group.options.count) option(s), allowsEmptySelection=\(group.allowsEmptySelection), default=\(group.defaultOption?.displayName ?? "nil")")
                for (index, option) in group.options.enumerated() {
                    let flags = [AVMediaCharacteristic.legible, .containsOnlyForcedSubtitles, .transcribesSpokenDialogForAccessibility,
                                 .describesMusicAndSoundForAccessibility, .isAuxiliaryContent, .easyToRead, .isMainProgramContent]
                        .filter { option.hasMediaCharacteristic($0) }.map { $0.rawValue.replacingOccurrences(of: "public.", with: "") }
                    lines.append("  #\(index) type=\(option.mediaType.rawValue) sub=\(option.mediaSubTypes.map { fourCC($0.uint32Value) }) tag=\(option.extendedLanguageTag ?? "nil") locale=\(option.locale?.identifier ?? "nil") name=\"\(option.displayName)\" playable=\(option.isPlayable)")
                    lines.append("     flags=\(flags)")
                }
            } catch {
                lines.append("  error: \(error.localizedDescription)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
