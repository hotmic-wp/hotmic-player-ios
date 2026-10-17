import Foundation
import HotMicPlayer

/// Canned ad decisions for the B/R demo, per the demo script's slot table. The creatives are
/// HotMic-made; in B/R's app the ad server and the side-car SDK decide and render.
/// - Slot 1: the 16:9 15 s pre-roll on every visit, and never the side-car.
/// - Slot 10: the 9:16 15 s pre-roll (B/R's "1 in 8" standard pre-roll).
/// - Slots 2 to 9: side-car eligible, once per session; `resetSideCar()` offers it again.
/// - Playlist P1 to P3 (a second playlist this session): no ads.
/// - Horizontal: side-car only on clips over 90 s, so H1 never; H2 yes (its stand-in uses 30 s).
@MainActor final class BRDemoAdProvider: HMAdBreakProvider {
    enum Decision: Equatable {
        case preRoll(BRDemoCreative)
        case sideCar
        case none
    }
    /// Whether the side-car has run this session.
    private(set) var sideCarShown = false
    private let catalog: BRDemoCatalog

    init(catalog: BRDemoCatalog = BRDemoContent.catalog) { self.catalog = catalog }

    func decision(for item: HMMediaItem) -> Decision {
        guard let clip = catalog.clip(forItemID: item.id) else { return .none }
        switch clip.ad {
        case "preRoll16x9", "preRoll9x16":
            return catalog.ads[clip.ad].map(Decision.preRoll) ?? Decision.none
        case "sideCar":
            guard catalog.section(forItemID: item.id) == .horizontal else { return .sideCar }
            let minimum = clip.sideCarMinimumDuration ?? catalog.horizontalSideCarMinimumDuration
            return clip.duration > minimum ? .sideCar : .none
        default:
            return .none
        }
    }
    func adBreak(for item: HMMediaItem) async throws -> HMAdBreak {
        switch decision(for: item) {
        case let .preRoll(creative): return .preRoll(creative.mediaItem())
        case .sideCar:
            // Horizontal eligibility remains available to task 5; only the vertical feed is wired here.
            guard catalog.section(forItemID: item.id) == .feed,
                  let creative = sideCarCreative(for: item),
                  let clip = catalog.clip(forItemID: item.id) else { return .none }
            sideCarDidShow()
            // The catalog's share destination is a real poster URL, used as a stand-in click-through.
            return .companion(.media(creative, clickThroughURL: clip.shareURL))
        case .none: return .none
        }
    }
    /// The 30 s 16:9 side-car creative for this item, or nil when the item isn't eligible or the
    /// side-car already ran this session.
    func sideCarCreative(for item: HMMediaItem) -> HMMediaItem? {
        guard !sideCarShown, decision(for: item) == .sideCar else { return nil }
        return catalog.ads["sideCar16x9_30"]?.mediaItem()
    }
    func sideCarDidShow() { sideCarShown = true }
    /// Offers the side-car on the next eligible visit, never on the current visit.
    func resetSideCar() { sideCarShown = false }
}
