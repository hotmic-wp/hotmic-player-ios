#if canImport(AVFoundation) && canImport(UIKit) && !os(watchOS)
import AVFoundation
import MediaAccessibility
import Observation
import UIKit

/// Small bounded cache shared by warm nodes. Downloads never gate video preparation or activation.
actor HMCaptionCache {
    static let shared = HMCaptionCache()
    private struct Entry {
        let cues: [HMCaptionCue]
        let expires: Date
    }
    private var values: [URL: Entry] = [:]
    private var tasks: [URL: Task<[HMCaptionCue], Never>] = [:]
    private let load: @Sendable (URL) async -> [HMCaptionCue]
    init(load: @escaping @Sendable (URL) async -> [HMCaptionCue] = HMCaptionCache.download) { self.load = load }
    func cues(for url: URL, prefetch: Bool = false) async -> [HMCaptionCue] {
        if let entry = values[url], entry.expires > Date() { return entry.cues }
        if let task = tasks[url] { return await task.value }
        // Speculative work is capped; an explicitly selected track is always admitted.
        guard (!prefetch || tasks.count < 8), ["file", "http", "https"].contains(url.scheme?.lowercased() ?? "") else { return [] }
        let load = load
        let task = Task.detached { await load(url) }
        tasks[url] = task
        let result = await task.value
        tasks[url] = nil
        if values.count >= 8, let key = values.keys.first { values[key] = nil }
        values[url] = Entry(cues: result, expires: result.isEmpty ? Date().addingTimeInterval(60) : .distantFuture)
        return result
    }
    private nonisolated static func download(_ url: URL) async -> [HMCaptionCue] {
        do {
            let data: Data
            if url.isFileURL {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 512 * 1024 else { return [] }
                data = try Data(contentsOf: url)
            } else {
                var request = URLRequest(url: url); request.timeoutInterval = 15
                let (received, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), received.count <= 512 * 1024 else { return [] }
                data = received
            }
            guard data.count <= 512 * 1024, let text = String(data: data, encoding: .utf8) else { return [] }
            return HMWebVTT.parse(text)
        } catch { return [] }
    }
}

@MainActor @Observable
final class HMCaptionController: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    private(set) var languages: [String] = []
    @ObservationIgnored var onLanguagesChanged: (() -> Void)?
    private(set) var selectedLanguage: String?
    private(set) var hlsText = ""
    private(set) var cues: [HMCaptionCue] = []
    private var enabled = false
    private var preference: String?
    private var sidecars: [String: URL] = [:]
    @ObservationIgnored private weak var item: AVPlayerItem?
    @ObservationIgnored private var group: AVMediaSelectionGroup?
    @ObservationIgnored private var audioGroup: AVMediaSelectionGroup?
    private var displaysForced = false
    @ObservationIgnored private var output: AVPlayerItemLegibleOutput?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var cueTask: Task<Void, Never>?
    private var usesOverlay = true

    func attach(_ item: AVPlayerItem, media: HMMediaItem) {
        reset()
        self.item = item; sidecars = media.captionSources
        languages = sidecars.keys.sorted()
        if !languages.isEmpty { onLanguagesChanged?() }
        let output = AVPlayerItemLegibleOutput()
        output.suppressesPlayerRendering = true
        output.setDelegate(self, queue: .main)
        item.add(output); self.output = output
        loadTask = Task { [weak self, weak item] in
            guard let item, let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                  !Task.isCancelled, let self, self.item === item else { return }
            let audioGroup = try? await item.asset.loadMediaSelectionGroup(for: .audible)
            guard !Task.isCancelled, self.item === item else { return }
            self.group = group; self.audioGroup = audioGroup
            let languages = Array(Set(self.languages + group.options.enumerated().filter { !$0.element.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }.map { self.language($0.element, index: $0.offset) })).sorted()
            let changed = self.languages != languages
            self.languages = languages
            self.applySelection()
            if changed { self.onLanguagesChanged?() }
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
    static func preferences(_ requested: String?) -> [String] {
        if let requested { return [requested] }
        return (MACaptionAppearanceCopySelectedLanguages(.user).takeRetainedValue() as? [String] ?? []) + Locale.preferredLanguages
    }
    static func matchLanguage(in languages: [String], preferences: [String]) -> String? {
        for preferred in preferences {
            if let exact = languages.first(where: { $0.caseInsensitiveCompare(preferred) == .orderedSame }) { return exact }
            let base = preferred.lowercased().split(separator: "-").first
            if let match = languages.first(where: { $0.lowercased().split(separator: "-").first == base }) { return match }
        }
        return nil
    }
    private func selectForcedOnly() {
        guard let group else { return }
        let audioLanguage = audioGroup.flatMap { item?.currentMediaSelection.selectedMediaOption(in: $0) }.flatMap { $0.extendedLanguageTag ?? $0.locale?.identifier }
        let preferences = audioLanguage.map { [$0] } ?? Self.preferences(nil)
        let options = group.options.enumerated().filter { $0.element.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
        let languages = options.map { language($0.element, index: $0.offset) }
        let match = Self.matchLanguage(in: languages, preferences: preferences)
        let forced = options.first { language($0.element, index: $0.offset) == match }?.element
        displaysForced = forced != nil
        item?.select(forced, in: group)
    }
    private func applySelection() {
        cueTask?.cancel(); cueTask = nil; cues = []; hlsText = ""; displaysForced = false
        selectedLanguage = enabled ? Self.matchLanguage(in: languages, preferences: Self.preferences(preference)) : nil
        guard let selectedLanguage else { selectForcedOnly(); return }
        if let url = sidecars[selectedLanguage] {
            selectForcedOnly()
            cueTask = Task { [weak self] in
                let cues = await HMCaptionCache.shared.cues(for: url)
                guard !Task.isCancelled, let self, self.selectedLanguage == selectedLanguage else { return }
                self.cues = cues
            }
        } else if let group, let option = group.options.enumerated().first(where: { !$0.element.hasMediaCharacteristic(.containsOnlyForcedSubtitles) && language($0.element, index: $0.offset) == selectedLanguage })?.element {
            item?.select(option, in: group)
        }
    }
    func text(at time: TimeInterval) -> String {
        guard enabled || displaysForced else { return "" }
        if sidecars[selectedLanguage ?? ""] != nil { return cues.filter { time >= $0.start && time < $0.end }.map(\.text).joined(separator: "\n") }
        return usesOverlay ? hlsText : ""
    }
    func reset() {
        loadTask?.cancel(); cueTask?.cancel()
        if let output { item?.remove(output) }
        item = nil; output = nil; group = nil; audioGroup = nil; displaysForced = false; languages = []; selectedLanguage = nil; cues = []; hlsText = ""
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
