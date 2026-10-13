import SwiftUI
import HotMicPlayer

/// Terminal cleanup follows the host screen's retained owner, not a transient cover.
@MainActor final class DemoPlayerOwner: ObservableObject {
    let player: HMPlayer
    init(player: HMPlayer) { self.player = player }
    deinit { MainActor.assumeIsolated { player.teardown() } }
}
