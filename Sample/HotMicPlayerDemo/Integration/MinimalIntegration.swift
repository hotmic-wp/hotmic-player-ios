import SwiftUI
import HotMicPlayer

/// The smallest complete integration, kept compiling so the snippet quoted in
/// `docs/INTEGRATION.md` can't rot into something that no longer builds.
///
/// Nothing in the demo references this. It exists to be counted and copied.
enum MinimalIntegration {

    // MARK: - Step 1 — point the SDK at your feed API (9 lines)

    struct ClipFeed: HMPlaylistSource {
        func loadPage(cursor: String?) async throws -> HMPlaylistPage {
            let page = try await ClipsAPI.clips(after: cursor)
            return HMPlaylistPage(
                items: page.clips.map {
                    HMMediaItem(id: $0.id, url: $0.hlsURL, posterURL: $0.posterURL, title: $0.headline)
                },
                nextCursor: page.nextCursor
            )
        }
    }

    // MARK: - Step 2 — render it, with your own overlay (7 lines)

    struct FeedScreen: View {
        @State private var controller = HMPlayer()

        var body: some View {
            HMVerticalFeedView(player: controller) { item, snapshot in
                HouseOverlay(item: item, snapshot: snapshot)
            }
            .task { controller.playlistSource = ClipFeed(); await controller.start() }
        }
    }

    // MARK: - Step 3 (optional) — wire analytics (4 lines)

    /// `@MainActor` because the hub and its sinks are main-actor isolated —
    /// they are touched from view bodies and from KVO callbacks that have
    /// already hopped to the main actor.
    @MainActor
    static func makeAnalytics(muxEnvironmentKey: String, viewerID: String) -> HMAnalyticsHub {
        let hub = HMAnalyticsHub()
        hub.add(HMMuxAnalyticsSink(environmentKey: muxEnvironmentKey, viewerUserID: viewerID))
        return hub
    }
}

// MARK: - Stand-ins for whatever the host app already has

/// Whatever the integrator's existing overlay chrome is. The SDK hands it an
/// item and a snapshot and stays out of the way.
private struct HouseOverlay: View {
    let item: HMMediaItem
    let snapshot: HMPlaybackSnapshot

    var body: some View {
        VStack {
            Spacer()
            Text(item.title ?? "")
            ProgressView(value: snapshot.progress)
        }
        .padding()
    }
}

/// Stands in for the host app's existing content API.
private enum ClipsAPI {
    struct Clip {
        let id: String
        let hlsURL: URL
        let posterURL: URL?
        let headline: String
    }

    struct Page {
        let clips: [Clip]
        let nextCursor: String?
    }

    static func clips(after cursor: String?) async throws -> Page {
        Page(clips: [], nextCursor: nil)
    }
}
