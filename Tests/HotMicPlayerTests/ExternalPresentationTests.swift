#if canImport(UIKit) && !os(watchOS)
import Foundation
import Testing
@_spi(Benchmark) @testable import HotMicPlayer

@Suite("Picture in Picture and external playback") @MainActor
struct ExternalPresentationTests {
    private func item(_ id: String, path: String? = nil) -> HMMediaItem {
        HMMediaItem(id: id, url: FileManager.default.temporaryDirectory.appendingPathComponent("hotmic-review-\(path ?? id).mp4"))
    }
    private func makePlayer() -> HMPlayer {
        let player = HMPlayer(configuration: HMPlayerConfiguration(managesAudioSession: false)); player.isFeedVisible = false
        return player
    }
    /// Tears the player down, which finishes the stream, and returns its presentation changes in order.
    private func presentationChanges(of player: HMPlayer, in stream: AsyncStream<HMPlayerEvent>) async -> [HMPlayerEvent] {
        player.teardown()
        var changes: [HMPlayerEvent] = []
        for await event in stream {
            if case .externalPresentationChanged(_, _) = event { changes.append(event) }
        }
        return changes
    }

    @Test("Host-reported Picture in Picture emits once per effective change and suppresses companion ads")
    func pictureInPicture() async {
        let player = makePlayer()
        let stream = player.events
        #expect(!player.isPictureInPictureActive && !player.isExternalPlaybackActive && !player.suppressesCompanionAds)
        player.isPictureInPictureActive = true
        #expect(player.suppressesCompanionAds)
        #expect(player.lastEvent == .externalPresentationChanged(pictureInPicture: true, externalPlayback: false))
        player.isPictureInPictureActive = true
        player.isPictureInPictureActive = false
        #expect(!player.suppressesCompanionAds)
        let changes = await presentationChanges(of: player, in: stream)
        #expect(changes == [
            .externalPresentationChanged(pictureInPicture: true, externalPlayback: false),
            .externalPresentationChanged(pictureInPicture: false, externalPlayback: false),
        ])
    }

    @Test("External playback follows the current content engine across item changes and pool swaps")
    func followsCurrentEngine() async {
        let player = makePlayer()
        let stream = player.events
        player.replaceAll([item("a"), item("b")])
        let a = player.pool.node(for: item("a"), protecting: [])
        let b = player.pool.node(for: item("b"), protecting: ["a"])
        // A warm neighbour on an external route is not current content.
        b.externalPlaybackChanged(true)
        #expect(!player.isExternalPlaybackActive && !player.suppressesCompanionAds)
        a.externalPlaybackChanged(true)
        #expect(player.isExternalPlaybackActive && player.suppressesCompanionAds)
        a.externalPlaybackChanged(true)
        // Item change: b is already external, so the flag holds without an event.
        player.jump(toID: "b")
        #expect(player.isExternalPlaybackActive)
        // The previous engine leaving the route is not current content either.
        a.externalPlaybackChanged(false)
        #expect(player.isExternalPlaybackActive)
        b.externalPlaybackChanged(false)
        #expect(!player.isExternalPlaybackActive)
        b.externalPlaybackChanged(true)
        #expect(player.isExternalPlaybackActive)
        // Pool swap: new media for the current entry releases its engine; the next engine decides.
        player.replaceAll([item("a"), item("b", path: "new-media")], startAt: 1)
        #expect(player.currentNode == nil && !player.isExternalPlaybackActive)
        b.externalPlaybackChanged(false)
        let swapped = player.pool.node(for: item("b", path: "new-media"), protecting: [])
        #expect(player.currentNode === swapped && !player.isExternalPlaybackActive)
        swapped.externalPlaybackChanged(true)
        #expect(player.isExternalPlaybackActive)
        let changes = await presentationChanges(of: player, in: stream)
        #expect(!player.isExternalPlaybackActive)
        #expect(changes == [
            .externalPresentationChanged(pictureInPicture: false, externalPlayback: true),
            .externalPresentationChanged(pictureInPicture: false, externalPlayback: false),
            .externalPresentationChanged(pictureInPicture: false, externalPlayback: true),
            .externalPresentationChanged(pictureInPicture: false, externalPlayback: false),
            .externalPresentationChanged(pictureInPicture: false, externalPlayback: true),
            // Teardown releases every engine.
            .externalPresentationChanged(pictureInPicture: false, externalPlayback: false),
        ])
    }

    @Test("External playback stays false while idle, binds on assignment and clears when the playlist empties")
    func idle() async {
        let player = makePlayer()
        let stream = player.events
        for node in player.pool.nodes { node.externalPlaybackChanged(true) }
        #expect(player.currentItem == nil && !player.isExternalPlaybackActive)
        player.replaceAll([item("a")])
        #expect(!player.isExternalPlaybackActive)
        // Assigning current content to an engine already on the route binds to it at once.
        player.pool.node(for: item("a"), protecting: [])
        #expect(player.isExternalPlaybackActive)
        player.replaceAll([])
        #expect(player.currentItem == nil && !player.isExternalPlaybackActive)
        let changes = await presentationChanges(of: player, in: stream)
        #expect(changes == [
            .externalPresentationChanged(pictureInPicture: false, externalPlayback: true),
            .externalPresentationChanged(pictureInPicture: false, externalPlayback: false),
        ])
    }

    @Test("The lab override drives external playback without a route and combines with Picture in Picture")
    func labOverride() async {
        let player = makePlayer()
        let stream = player.events
        player.externalPlaybackOverride = true
        #expect(player.isExternalPlaybackActive && player.suppressesCompanionAds)
        player.isPictureInPictureActive = true
        player.externalPlaybackOverride = nil
        #expect(!player.isExternalPlaybackActive && player.suppressesCompanionAds)
        player.isPictureInPictureActive = false
        #expect(!player.suppressesCompanionAds)
        let changes = await presentationChanges(of: player, in: stream)
        #expect(changes == [
            .externalPresentationChanged(pictureInPicture: false, externalPlayback: true),
            .externalPresentationChanged(pictureInPicture: true, externalPlayback: true),
            .externalPresentationChanged(pictureInPicture: true, externalPlayback: false),
            .externalPresentationChanged(pictureInPicture: false, externalPlayback: false),
        ])
    }
}
#endif
