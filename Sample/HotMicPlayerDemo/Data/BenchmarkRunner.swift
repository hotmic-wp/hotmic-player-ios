import Foundation
import Observation
import UIKit
@_spi(Benchmark) import HotMicPlayer

/// All device paths run this autopilot. XCTest only starts it and waits.
@MainActor @Observable
final class BenchmarkRunner {
    private(set) var controller: HMPlayer?
    private(set) var isRunning = false
    private(set) var complete = false
    private(set) var progress = "Ready"
    private(set) var failure: String?
    private(set) var uploadsFailed = 0
    private(set) var completedRuns = 0
    private(set) var totalRuns = 0
    private(set) var localFiles: [URL] = []
    private(set) var pageNumber = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var sink: HMJSONLFileSink?
    @ObservationIgnored private var observedIDs: [String] = []
    @ObservationIgnored private var currentExpectedIndex: Int?
    @ObservationIgnored private var playbackError: String?
    @ObservationIgnored private let options = BenchmarkOptions()

    func start(urlString: String) {
        guard !isRunning else { return }
        failure = nil; complete = false; isRunning = true; completedRuns = 0; uploadsFailed = 0
        UserDefaults.standard.set(urlString, forKey: "HMGridURL")
        task = Task { [weak self] in
            guard let self else { return }
            let oldIdle = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = oldIdle; isRunning = false; task = nil }
            do { try await runGrid(urlString); complete = true; progress = "Complete: \(completedRuns) runs, \(uploadsFailed) upload failures" }
            catch {
                if let controller { await controller.finishRun(); controller.teardown() }
                try? await sink?.flush()
                failure = error.localizedDescription; progress = "Stopped: \(error.localizedDescription)"
            }
        }
    }
    func cancel() { task?.cancel() }
    private func runGrid(_ raw: String) async throws {
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme) else { throw BenchmarkOptions.Invalid("grid-url") }
        progress = "Fetching grid"
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BenchmarkOptions.Invalid("grid HTTP status") }
        let grid = try JSONDecoder().decode(BenchmarkGrid.self, from: data)
        guard !grid.cells.isEmpty, grid.cells.count <= 1000,
              Set(grid.cells.map(\.id)).count == grid.cells.count,
              let resultURL = URL(string: grid.resultsURL, relativeTo: url)?.absoluteURL,
              ["http", "https"].contains(resultURL.scheme) else { throw BenchmarkOptions.Invalid("grid cells/results_url") }
        guard isSafeID(grid.runPrefix) else { throw BenchmarkOptions.Invalid("run_prefix") }
        // Validate the entire grid before playing its first cell.
        for cell in grid.cells {
            guard isSafeID(cell.id), (1...100).contains(cell.repeats), (0...10000).contains(cell.swipes ?? 50),
                  ["binge", "normal", "watchThrough", "backAndForth", "jumpTo20"].contains(cell.script),
                  cell.dwellSeconds == nil || (cell.dwellSeconds!.isFinite && cell.dwellSeconds! >= 0) else { throw BenchmarkOptions.Invalid("cell \(cell.id)") }
            _ = try cellOptions(cell, grid: grid, base: url).configuration()
        }
        totalRuns = grid.cells.reduce(0) { $0 + $1.repeats }
        let sessionID = UUID().uuidString.prefix(8)
        for cell in grid.cells {
            for repetition in 0..<cell.repeats {
                try Task.checkCancellation()
                let runID = safe(grid.runPrefix + "-" + String(sessionID) + "-" + cell.id + "-r\(repetition)")
                progress = "Run \(completedRuns + 1)/\(totalRuns): \(cell.id), repeat \(repetition + 1)"
                let file = try await runCell(cell, grid: grid, base: url, runID: runID)
                localFiles.append(file)
                // Flush completes before upload. Every run keeps its local copy,
                // whether or not the remote receiver acknowledges it.
                progress = "Uploading \(completedRuns + 1)/\(totalRuns): \(cell.id)"
                do {
                    var request = URLRequest(url: resultURL); request.httpMethod = "POST"
                    request.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
                    request.setValue(runID, forHTTPHeaderField: "X-HotMic-Run-ID")
                    let (_, response) = try await session.upload(for: request, fromFile: file)
                    guard let code = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(code) else { throw BenchmarkOptions.Invalid("results HTTP status") }
                } catch { uploadsFailed += 1 }
                completedRuns += 1
                controller?.teardown(); controller = nil; sink = nil
                // Ensure the old scroll view and display links leave the window
                // before assigning a new feed with potentially identical IDs.
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }
    private func cellOptions(_ cell: BenchmarkGrid.Cell, grid: BenchmarkGrid, base: URL) throws -> BenchmarkOptions {
        guard let playlist = URL(string: cell.playlistURL, relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(playlist.scheme) else { throw BenchmarkOptions.Invalid("playlist_url") }
        var values = ["strategy": cell.strategy, "format": cell.format, "network": grid.network,
                      "manifest-url": playlist.absoluteString, "run-id": "grid", "script": cell.script]
        let supported: Set<String> = ["players", "ahead", "behind", "prefetch-bytes", "prefetch-seconds", "threshold", "cache-cap", "startup-bitrate", "startup-window", "steady-bitrate", "steady-buffer", "warm-buffer"]
        for (key, number) in cell.knobs ?? [:] {
            guard supported.contains(key), number.isFinite else { throw BenchmarkOptions.Invalid("knob \(key)") }
            values[key] = String(format: "%.15g", number)
        }
        return BenchmarkOptions(values: values)
    }
    private func runCell(_ cell: BenchmarkGrid.Cell, grid: BenchmarkGrid, base: URL, runID: String) async throws -> URL {
        if cell.resetCache ?? true {
            await HMPlayerCache.reset()
        }
        let cellOptions = try cellOptions(cell, grid: grid, base: base)
        let configuration = try cellOptions.configuration()
        let source = try await cellOptions.dataSource()
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("BenchRuns/\(runID).jsonl")
        let createdSink = try HMJSONLFileSink(fileURL: file, runID: runID, configuration: configuration,
            format: cell.format, network: grid.network, script: cell.script,
            buildSHA: options.values["build-sha"] ?? (Bundle.main.object(forInfoDictionaryKey: "HMBuildSHA") as? String ?? "unknown"),
            dimensions: ["grid_url": base.absoluteString, "cell_id": cell.id, "reset_cache": String(cell.resetCache ?? true), "paging": "in-app-settled-page", "swipes": String(cell.swipes ?? 50)])
        sink = createdSink
        observedIDs = []; playbackError = nil; pageNumber = 0
        let hub = HMAnalyticsHub(sinks: [createdSink])
        hub.add(ValidationSink { [weak self] event in
            guard let self else { return }
            if event.kind == .viewStart {
                observedIDs.append(event.itemID)
                if let index = currentExpectedIndex, controller?.items.indices.contains(index) == true,
                   controller?.items[index].id != event.itemID { playbackError = "Wrong item activated: \(event.itemID)" }
            }
            if event.kind == .error { playbackError = event.properties["error_message"] ?? "Decoder error" }
        })
        let created = HMPlayer(configuration: configuration, analytics: hub)
        created.playlistSource = source
        created.isFeedVisible = false
        await created.start()
        guard created.loadError == nil else { throw BenchmarkOptions.Invalid(created.loadError!) }
        let initial = cell.script == "jumpTo20" ? 19 : 0
        let swipes = cell.swipes ?? 50
        let last = cell.script == "backAndForth" ? initial + (swipes > 0 ? 1 : 0) : initial + swipes
        guard created.items.indices.contains(initial), created.items.indices.contains(last) else { throw BenchmarkOptions.Invalid("playlist too short for \(cell.id)") }
        currentExpectedIndex = initial
        controller = created
        await created.requestPlay(at: initial)
        let dwell = cell.dwellSeconds ?? (cell.script == "binge" ? 1 : 5)
        for swipe in 0..<swipes {
            try Task.checkCancellation()
            if cell.requireFrame ?? false { try await awaitFrame(created) }
            let seconds = cell.script == "watchThrough" ? (created.currentItem?.durationHint ?? created.snapshot.duration) + 0.2 : dwell
            try await Task.sleep(for: .seconds(seconds))
            try await awaitForeground()
            if let playbackError { throw BenchmarkOptions.Invalid(playbackError) }
            let backwards = cell.script == "backAndForth" && swipe % 2 == 1
            let next = created.activeIndex + (backwards ? -1 : 1)
            currentExpectedIndex = next
            created.requestPage(at: next)
            try await awaitPage(created, index: next)
            pageNumber += 1
        }
        if cell.requireFrame ?? false { try await awaitFrame(created) }
        try await Task.sleep(for: .seconds(dwell))
        guard observedIDs.count == swipes + 1 else { throw BenchmarkOptions.Invalid("missing page activations") }
        if let playbackError { throw BenchmarkOptions.Invalid(playbackError) }
        await created.finishRun()
        try await createdSink.flush()
        return file
    }
    private func awaitForeground() async throws {
        while UIApplication.shared.applicationState != .active { try await Task.sleep(for: .milliseconds(100)) }
    }
    private func awaitPage(_ controller: HMPlayer, index: Int) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while controller.activeIndex != index {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw BenchmarkOptions.Invalid("page commit timeout at \(index)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private func awaitFrame(_ controller: HMPlayer) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while controller.snapshot.timeToFirstFrame == nil {
            try Task.checkCancellation()
            if let playbackError { throw BenchmarkOptions.Invalid(playbackError) }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw BenchmarkOptions.Invalid("missing displayed frame at \(controller.activeIndex)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private func isSafeID(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 64 && text.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
    private func safe(_ text: String) -> String { String(text.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }) }
    @MainActor private final class ValidationSink: HMAnalyticsSink {
        let sinkName = "benchmark-validation"
        let event: (HMPlaybackEvent) -> Void
        init(_ event: @escaping (HMPlaybackEvent) -> Void) { self.event = event }
        func handle(_ event: HMPlaybackEvent, item: HMMediaItem) { self.event(event) }
    }
}
