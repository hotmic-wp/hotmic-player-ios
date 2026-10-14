import Foundation
#if os(iOS)
import UIKit
#endif

@MainActor final class HMDiagnosticsRecorder {
    enum Observation { case attempt, firstFrame(Double), endedBeforeFrame, moving(Double), stall(Double) }
    private(set) var aggregate: HMDiagnosticsAggregate?
    private(set) var began: TimeInterval
    private let rate: Double
    private var config: HMDiagnosticsConfig?
    private var timer: DispatchSourceTimer?
    private var transport: HMDiagnosticsTransport?
    private var memoryObserver: NSObjectProtocol?
    private let options: HMPlayerDiagnosticsConfiguration
    private let eligible: @MainActor () -> Bool
    private let cadence: HMDiagnosticsCadence
    var lastAttempt: TimeInterval { cadence.lastAttempt }
    init(options: HMPlayerDiagnosticsConfiguration, configuration: HMPlayerConfiguration,
         lastAttempt: TimeInterval, cadence: HMDiagnosticsCadence? = nil, eligible: @escaping @MainActor () -> Bool) {
        self.options = options; rate = options.samplingPercent / 100
        self.cadence = cadence ?? HMDiagnosticsCadence(lastAttempt: lastAttempt); self.eligible = eligible
        began = ProcessInfo.processInfo.systemUptime
        config = HMDiagnosticsConfig(configuration)
        resume()
    }
    func resume() {
        guard timer == nil, options.endpoint != nil else { return }
        began = ProcessInfo.processInfo.systemUptime
        aggregate = config.map { HMDiagnosticsAggregate(config: $0, rate: rate) }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 60, repeating: 60, leeway: .milliseconds(250))
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.close() } }
        timer = source; source.resume()
        #if os(iOS)
        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.discardForPressure() }
            }
        #endif
    }
    func suspend() {
        timer?.cancel(); timer = nil; aggregate = nil
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
        memoryObserver = nil
        transport?.cancel(); transport = nil
    }
    func cancelDelivery() { transport?.cancel(); transport = nil }
    func discardForPressure() {
        aggregate?.invalid = true
        transport?.cancel(); transport = nil
    }
    func configure(_ configuration: HMPlayerConfiguration) {
        let next = HMDiagnosticsConfig(configuration)
        guard next != config else { return }
        config = next; began = ProcessInfo.processInfo.systemUptime
        aggregate = timer == nil ? nil : next.map { HMDiagnosticsAggregate(config: $0, rate: rate) }
    }
    func record(_ observation: Observation, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        // Later events never enter an expired window, even if the timer wakes late.
        guard now >= began, now < began + 60, aggregate != nil, aggregate?.invalid == false else { return }
        // Mutate the one owned value in place: no event arrays, per-item state or tasks.
        switch observation {
        case .attempt:
            guard aggregate!.playback.attempted < 10_000 else { aggregate!.invalid = true; return }
            aggregate!.playback.attempted += 1
        case .endedBeforeFrame:
            guard aggregate!.playback.ended_before_first_frame < 10_000 else { aggregate!.invalid = true; return }
            aggregate!.playback.ended_before_first_frame += 1
        case .firstFrame(let ms):
            guard let b = HMDiagnosticsAggregate.bucket(ms), aggregate!.playback.first_frames < 10_000 else { aggregate!.invalid = true; return }
            aggregate!.playback.first_frames += 1; aggregate!.startup_buckets[b] += 1
        case .moving(let ms):
            guard let b = HMDiagnosticsAggregate.bucket(ms), aggregate!.moving_start_buckets.reduce(0, +) < 10_000 else { aggregate!.invalid = true; return }
            aggregate!.moving_start_buckets[b] += 1
        case .stall(let ms):
            guard ms.isFinite, ms >= 0, ms <= 86_400_000,
                  aggregate!.stalls.count < 10_000,
                  aggregate!.stalls.total_duration_ms <= 86_400_000 - Int(ms.rounded()) else { aggregate!.invalid = true; return }
            aggregate!.stalls.count += 1; aggregate!.stalls.total_duration_ms += Int(ms.rounded())
        }
    }
    func close(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let elapsed = now - began
        defer {
            began = now
            aggregate = config.map { HMDiagnosticsAggregate(config: $0, rate: rate) }
        }
        // Two intervals defines stale. Ordinary scheduling jitter remains sendable.
        guard elapsed >= 60, elapsed < 120, var snapshot = aggregate, !snapshot.invalid,
              eligible(), now - lastAttempt >= 60, transport?.busy != true, let endpoint = options.endpoint else { return }
        if transport == nil { transport = HMDiagnosticsTransport(endpoint: endpoint, appKey: options.appKey, cadence: cadence) }
        snapshot.window_duration_ms = Int(min(elapsed * 1000, 60_000))
        _ = transport?.submit(snapshot)
    }
    deinit {
        timer?.cancel(); transport?.cancel()
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
    }
}
