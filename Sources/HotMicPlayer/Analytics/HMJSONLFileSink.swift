import Foundation
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

/// Ordered, asynchronous file writes. `flush()` is the export barrier; errors
/// are surfaced to callers instead of silently claiming a complete run.
@MainActor
public final class HMJSONLFileSink: HMAnalyticsSink {
    public let sinkName = "jsonl"
    public let fileURL: URL
    private let writer: Writer
    public init(fileURL: URL, runID: String, configuration: HMPlayerConfiguration,
                format: String, network: String, script: String, buildSHA: String) throws {
        self.fileURL = fileURL
        writer = try Writer(fileURL)
        var model = utsname(); uname(&model)
        let device = withUnsafeBytes(of: &model.machine) { bytes in String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) }
        let header: [String: Any] = ["type": "runHeader", "schema": 1, "run_id": runID,
            "strategy": configuration.strategy.rawValue, "configuration": configuration.fingerprint,
            "configuration_sha256": HMCacheKey.hash(configuration.fingerprint), "format": format,
            "network": network, "script": script, "device_model": ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? device,
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "build_sha": buildSHA,
            "started_at": ISO8601DateFormatter().string(from: Date()),
            "clock": "systemUptime", "simulator": ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] != nil]
        writer.append(try Self.line(header))
    }
    public func handle(_ event: HMPlaybackEvent, item: HMMediaItem) {
        let object: [String: Any] = ["type": "event", "event": event.kind.rawValue,
            "event_id": event.id.uuidString, "item_id": event.itemID,
            "monotonic_s": event.monotonicTime, "position_s": event.position,
            "metrics": event.metrics.filter { $0.value.isFinite }, "properties": event.properties]
        do { writer.append(try Self.line(object)) } catch { writer.record(error) }
    }
    public func flush() async throws { try await writer.flush() }
    private static func line(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(10); return data
    }
    private final class Writer: @unchecked Sendable {
        let queue = DispatchQueue(label: "com.hotmic.analytics.jsonl")
        let handle: FileHandle
        var failure: Error?
        init(_ url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            handle = try FileHandle(forWritingTo: url)
        }
        deinit { try? handle.close() }
        func append(_ data: Data) {
            queue.async { [self] in do { try handle.write(contentsOf: data) } catch { failure = error } }
        }
        func record(_ error: Error) { queue.async { [self] in failure = error } }
        func flush() async throws {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    do { try handle.synchronize(); if let failure { throw failure }; c.resume() }
                    catch { c.resume(throwing: error) }
                }
            }
        }
    }
}
