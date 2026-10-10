#if canImport(AVFoundation) && canImport(UIKit) && !os(watchOS)
import AVFoundation
import MediaAccessibility
import Observation
import UIKit

/// Small bounded cache shared by warm nodes. Downloads never gate video preparation or activation.
actor HMCaptionCache {
    static let shared = HMCaptionCache()
    private var values: [URL: [HMCaptionCue]] = [:]
    private var tasks: [URL: Task<[HMCaptionCue], Never>] = [:]
    func cues(for url: URL) async -> [HMCaptionCue] {
        if let value = values[url] { return value }
        if let task = tasks[url] { return await task.value }
        guard tasks.count < 8, ["file", "http", "https"].contains(url.scheme?.lowercased() ?? "") else { return [] }
        let task = Task<[HMCaptionCue], Never> {
            do {
                var data = Data()
                if url.isFileURL {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 512 * 1024 else { return [] }
                    data = try Data(contentsOf: url)
                } else {
                    var request = URLRequest(url: url); request.timeoutInterval = 15
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), response.expectedContentLength <= 512 * 1024 else { return [] }
                    for try await byte in bytes {
                        guard data.count < 512 * 1024, !Task.isCancelled else { return [] }
                        data.append(byte)
                    }
                }
                guard let text = String(data: data, encoding: .utf8) else { return [] }
                return HMWebVTT.parse(text)
            } catch { return [] }
        }
        tasks[url] = task
        let result = await task.value
        tasks[url] = nil
        if values.count >= 8, let key = values.keys.first { values[key] = nil }
        if !result.isEmpty { values[url] = result }
        return result
    }
}

@MainActor @Observable
final class HMCaptionController: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    private(set) var languages: [String] = []
    private(set) var selectedLanguage: String?
    private(set) var hlsText = ""
    private(set) var cues: [HMCaptionCue] = []
    private var enabled = false
    private var preference: String?
    private var sidecars: [String: URL] = [:]
    @ObservationIgnored private weak var item: AVPlayerItem?
    @ObservationIgnored private var group: AVMediaSelectionGroup?
    @ObservationIgnored private var output: AVPlayerItemLegibleOutput?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var cueTask: Task<Void, Never>?
    private var usesOverlay = true

    func attach(_ item: AVPlayerItem, media: HMMediaItem) {
        reset()
        self.item = item; sidecars = media.captionSources
        languages = sidecars.keys.sorted()
        let output = AVPlayerItemLegibleOutput()
        output.suppressesPlayerRendering = true
        output.setDelegate(self, queue: .main)
        item.add(output); self.output = output
        loadTask = Task { [weak self, weak item] in
            guard let item, let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                  !Task.isCancelled, let self, self.item === item else { return }
            self.group = group
            self.languages = Array(Set(self.languages + group.options.enumerated().map { self.language($0.element, index: $0.offset) })).sorted()
            self.applySelection()
        }
        applySelection()
    }
    func configure(enabled: Bool, language: String?) {
        guard self.enabled != enabled || preference != language else { return }
        self.enabled = enabled; preference = language; applySelection()
    }
    func renderInOverlay(_ overlay: Bool) {
        guard usesOverlay != overlay else { return }
        usesOverlay = overlay; output?.suppressesPlayerRendering = overlay
    }
    private func language(_ option: AVMediaSelectionOption, index: Int) -> String {
        option.extendedLanguageTag ?? option.locale?.identifier ?? "und-\(index)"
    }
    private func applySelection() {
        cueTask?.cancel(); cueTask = nil; cues = []; hlsText = ""
        let preferred = preference ?? (MACaptionAppearanceCopySelectedLanguages(.user).takeRetainedValue() as? [String])?.first ?? Locale.preferredLanguages.first
        selectedLanguage = enabled ? languages.first(where: { $0.caseInsensitiveCompare(preferred ?? "") == .orderedSame }) ?? languages.first(where: { $0.split(separator: "-").first == preferred?.split(separator: "-").first }) ?? languages.first : nil
        guard let selectedLanguage else { if let group { item?.select(nil, in: group) }; return }
        if let url = sidecars[selectedLanguage] {
            if let group { item?.select(nil, in: group) }
            cueTask = Task { [weak self] in
                let cues = await HMCaptionCache.shared.cues(for: url)
                guard !Task.isCancelled, let self, self.selectedLanguage == selectedLanguage else { return }
                self.cues = cues
            }
        } else if let group, let option = group.options.enumerated().first(where: { language($0.element, index: $0.offset) == selectedLanguage })?.element {
            item?.select(option, in: group)
        }
    }
    func text(at time: TimeInterval) -> String {
        guard enabled else { return "" }
        if sidecars[selectedLanguage ?? ""] != nil { return cues.filter { time >= $0.start && time < $0.end }.map(\.text).joined(separator: "\n") }
        return usesOverlay ? hlsText : ""
    }
    func reset() {
        loadTask?.cancel(); cueTask?.cancel()
        if let output { item?.remove(output) }
        item = nil; output = nil; group = nil; languages = []; selectedLanguage = nil; cues = []; hlsText = ""
    }
    nonisolated func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString], nativeSampleBuffers: [Any], forItemTime itemTime: CMTime) {
        MainActor.assumeIsolated {
            guard self.output === output else { return }
            hlsText = strings.map(\.string).joined(separator: "\n")
        }
    }
    nonisolated func outputSequenceWasFlushed(_ output: AVPlayerItemOutput) {
        MainActor.assumeIsolated { if self.output === output { hlsText = "" } }
    }
}
#endif
