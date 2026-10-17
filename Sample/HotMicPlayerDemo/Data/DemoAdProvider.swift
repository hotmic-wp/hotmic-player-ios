import Foundation
import UIKit
import HotMicPlayer

/// Fake existing host stack: no network, beacons or SDK dependencies.
@MainActor final class DemoAdProvider: HMAdBreakProvider {
    let preRollURL: URL
    let everyVisit: Bool
    /// Trigger for the lab's companion item; short defaults keep the walk-through quick.
    var companionTrigger = HMCompanionTrigger(watchedTime: 3, countdown: 2)
    private var task: Task<Void, Never>?
    init(preRollURL: URL, everyVisit: Bool = false) { self.preRollURL = preRollURL; self.everyVisit = everyVisit }
    func adBreak(for item: HMMediaItem) async throws -> HMAdBreak {
        if item.id == "companion-ad" {
            let creative = HMMediaItem(id: "local-companion", url: preRollURL, format: .mp4, aspectRatio: 16.0 / 9, presentation: .fit)
            return .companion(.media(creative, clickThroughURL: URL(string: "https://example.com/offer"), trigger: companionTrigger))
        }
        if everyVisit || item.id == "url-ad" {
            return .preRoll(HMMediaItem(id: "local-preroll", url: preRollURL, format: .mp4, aspectRatio: 16.0 / 9, presentation: .fit))
        }
        if item.id == "slow-ad" {
            try await Task.sleep(for: .seconds(5))
            return .none
        }
        guard ["host-ad", "hung-ad", "endless-ad"].contains(item.id) else { return .none }
        return .hostPlayed(HMHostAdBreak(start: { [weak self] context in
            let label = UILabel()
            label.textColor = .white; label.textAlignment = .center; label.numberOfLines = 0
            label.font = .boldSystemFont(ofSize: 24)
            label.backgroundColor = .systemIndigo
            context.container.addSubview(label); label.translatesAutoresizingMaskIntoConstraints = false
            // The fake SDK renders its landscape creative with aspect fit in the supplied safe area.
            let width = label.widthAnchor.constraint(equalTo: context.container.widthAnchor)
            width.priority = .defaultHigh
            NSLayoutConstraint.activate([width, label.widthAnchor.constraint(lessThanOrEqualTo: context.container.widthAnchor),
                label.heightAnchor.constraint(lessThanOrEqualTo: context.container.heightAnchor), label.centerXAnchor.constraint(equalTo: context.container.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: context.container.centerYAnchor),
                label.heightAnchor.constraint(equalTo: label.widthAnchor, multiplier: 9.0 / 16)])
            self?.task = Task { @MainActor in
                var tick = 0
                while tick < 30 || item.id == "endless-ad" {
                    if !context.isPlaybackAllowed {
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                        continue
                    }
                    guard !Task.isCancelled else { return }
                    let elapsed = Double(tick) / 5
                    label.text = "Host ad · \(Int(ceil(6 - elapsed)))s\nExisting skip/countdown UI"
                    if item.id != "hung-ad" { context.updateProgress(HMAdProgress(elapsed: elapsed, duration: 6)) }
                    if item.id != "hung-ad" { tick += 1 }
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                }
                context.complete()
            }
        }, stop: { [weak self] _ in self?.task?.cancel(); self?.task = nil }))
    }
}
