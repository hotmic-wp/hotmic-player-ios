# Playlist management

Edit the loaded playlist atomically without rebuilding the feed.

## Playlist operations

IDs must be nonempty and unique across the resulting playlist. These calls are synchronous on the main actor and return a success Boolean. Invalid edits leave the previous playlist intact and emit ``HMPlayerEvent/error(item:kind:)``. Successful effective edits emit `playlistChanged` and, if necessary, `currentItemChanged`.

| Operation | Playback effect |
| --- | --- |
| `replaceAll(_:startAt:)` | Selects the supplied index and resets paging to a nil cursor. Empty with index zero becomes idle. |
| `replaceUpcoming(_:)` | Replaces every entry after current; keeps current clock, buffer and layer. |
| `insertNext(_:)` | Inserts immediately after current; creates a playlist when empty. |
| `append(_:)` | Adds to the end and preserves current playback. |
| `remove(ids:)` | Removes matching IDs using `removedCurrentPolicy`. |
| `reconcile(_:)` | Reconciles a complete ranked feed around current, preserving history and replacing upcoming entries. |

```swift
player.replaceAll([intro, replay], startAt: 0)
player.replaceUpcoming([replay, finale])
player.insertNext([sponsor])
player.append([bonus])
player.remove(ids: [sponsor.id])
```

Identical `replaceAll` (including the selected index), empty appends/inserts and removing unknown IDs are silent no-ops: no revision, events, releases, cursor reset or prefetch cancellation. They also preserve remembered failures, resume positions and `loadError`. A same-ID refresh with an unchanged source updates title/poster/metadata in place, preserving the native player, clock, layer and downloaded bytes. A non-identical `replaceAll` with the same selected ID and media source likewise preserves playback, emits no `currentItemChanged`, and retains overlapping pool assignments. Changing the media source replaces that player's assignment and resets its saved resume position. Effective `replaceAll` edits still reset paging; they do not clear failures for unchanged media.

Media identity is the item ID plus source (including format), excluding display metadata. URL identity uses the same canonical key as the cache: only explicitly configured `volatileSigningQueryParameters` are stripped; other query parameters remain significant. Re-signing those configured parameters preserves active/warm players and downloads. The current native asset continues using its original URL; new assignments use the latest URL.

Edits preserve overlapping prefetch work. Reordering or editing outside the media window does not cancel downloads; a window change cancels only entries that left it. Fixed-mode buffer pressure and temporary visibility changes park surviving speculative work; changed budgets may restart it. During a swipe, an edit preserves the move unless the current or destination ID changes position. Appending does not interrupt a swipe. Item identity also scopes moderation: removing an item ends its retained records; re-inserting the same ID begins a new lifetime.

## Ranked feed refresh

A complete ranked response can include history and current. Reconciliation finds current by ID, updates its display metadata, and routes only the entries after it through `replaceUpcoming`. Played history stays unchanged. History IDs ranked after current are ignored, so a previously played entry is not replayed or duplicated. Entries before current that are not history are ignored. Duplicate or empty IDs anywhere in the incoming list reject the entire edit, even in the ignored prefix. Invalid URLs also reject the edit.

```swift
// On the main actor, after each complete feed response:
func refreshRankedFeed(_ rankedItems: [HMMediaItem], player: HMPlayer) {
    guard player.reconcile(rankedItems) else { return } // inspect loadError/events on rejection
    if let change = player.lastPlaylistChange {
        animateFeed(inserted: change.insertedIDs,
                    removed: change.removedIDs,
                    moved: change.movedIDs)
    }
}
```

An empty incoming list is a no-op, including while current is playing. An empty player loads a nonempty incoming list. If current is missing, reconciliation keeps history, treats every incoming nonhistory item as upcoming, and applies `removedCurrentPolicy`: first upcoming, otherwise idle, without selecting an already-played history entry. A history-only response goes idle immediately with `.advanceNow`, or after the finishing current ends with `.finishThenAdvance`. History remains in `items`; `currentIndex` is nil while idle. Later nonhistory entries can resume the feed.

## Removed current

`HMPlayerConfiguration.removedCurrentPolicy` defaults to `.advanceNow`, which immediately removes current and selects the next survivor, then previous, then idle. `.finishThenAdvance` keeps the removed current entry in `items` until its next natural end, suppresses looping for this visit even when `loops` is true, and then removes and advances it. A current entry that has already ended, failed, or become failure-idle advances immediately because no further playable end is available. A finishing entry that subsequently fails also advances. Other requested removals apply immediately. Swiping or jumping away removes it immediately and selects the requested entry. Repeated refreshes cannot extend or loop that finishing visit, even if current reappears in the ranked feed. An effective `replaceAll` starts a new playlist selection and clears the deferred removal; an identical replacement remains a no-op.

```swift
var configuration = HMPlayerConfiguration()
configuration.removedCurrentPolicy = .finishThenAdvance
let player = HMPlayer(configuration: configuration)
```

## Edit summaries and warm badges

`lastPlaylistChange` is an observable optional `HMPlaylistChange`, a Sendable, Equatable value. It describes the last effective edit: `insertedIDs`, `removedIDs`, `movedIDs`, `currentChanged`, `releasedItemIDs` and `releasedPlayerCount`. Moved IDs include surviving entries whose absolute index shifted because of insertion/removal. Current changes mean ID or canonical source changes, not display metadata or configured signing query values. The public initializer supports host tests and previews. Release IDs identify item assignments whose native player was released or reassigned synchronously by the edit; later asynchronous warming is separate. Deferred removal is reported as removed only when the finishing entry leaves. Metadata-only edits have empty ID lists, false currentChanged and zero releases. No-ops and rejected edits preserve the previous summary; use `playlistRevision` to observe each effective edit, including equal summaries.

For an inactive prepared neighbour, `snapshot(for: entry).readinessTier` reports `.warmPlayer` once a decoded frame is ready, otherwise `.resolved`. An unprepared entry reports `.cold`. Active snapshots preserve readiness measured at activation. A warm badge can use `player.currentItem?.id != entry.id && player.snapshot(for: entry).readinessTier == .warmPlayer`.

## Paged feeds

Implement a `Sendable` source, preferably an actor for mutable state:

```swift
actor Catalog: HMPlaylistSource {
    func loadPage(cursor: String?) async throws -> HMPlaylistPage {
        // Replace with your network request. A nil next cursor ends paging.
        HMPlaylistPage(items: [], nextCursor: nil)
    }
}
// On the main actor:
player.playlistSource = Catalog()
await player.start()
```

A pending page merges into the latest playlist. `replaceAll` resets the cursor and ignores an older response. Assigning a source or tearing down cancels its pending fetch. Repeated IDs in source pages are filtered and reported by `sourcePageDuplicates`; the cursor still advances. A repeated cursor ends paging.

Paging failures get four total attempts with 1/2/4-second backoff, then wait for navigation or explicit `loadNextPage()`. That method returns without throwing; inspect `loadError` and events. Sources should honor task cancellation.

## Resolve opaque items

``HMItemResolver/resolve(_:)`` receives a namespace and ID and returns ``HMResolvedItem`` with a URL and optional format, title, poster and duration. Give each playlist entry a stable unique ID, even when media URLs repeat. Completed resolutions are session-cached; pending work follows the prefetch window. Explicit `.mp4` or `.hls` avoids auto-format probing. Resolution and first-frame timing begin at the committed selection.

## Failed media

Default `.skip` tries the next nonfailed entry, then previous, then idle. `.stay` keeps the failed entry selected. Failed items remain in the playlist and are excluded from automatic traversal. Failure memory follows media identity: identical, metadata-only and configured signing-only refreshes do not reset terminal, network or resolution failures. Call `jump(toID:)` to explicitly retry a failed entry, even if it is already selected. A real source change starts a new failure/resume lifetime. Transient network failures retry only current/next with jittered waits capped at 30 seconds; attempts continue while eligible and do not spend the terminal failure budget. A native retry keeps the selected entry ID and original action clock but creates a fresh analytics activation/viewStart; distinguish activation attempts from unique viewed entries when measuring coverage. Terminal resolver/prefix attempts and page attempts are separately capped. Skips wait for page motion and interactions to settle. Wrap custom scrubbers or menus with `beginInteraction()` / `endInteraction()`; a missing end expires after 30 seconds.

## Public-import operation recipe

Call these operations in response to host actions; this compiled recipe shows the API and lifetime ownership together. `reconcile` preserves history around current, so entries before it are not a full-history replacement. `reconcile([])` is a no-op, while `replaceAll([])` clears. A finishing visit keeps its existing media when a ranked refresh reintroduces its ID, so repeated refreshes cannot restart/prolong it. Explicit replaceAll remains a replacement action.

```swift
import HotMicPlayer
@MainActor func partnerQueueRecipe(source: any HMPlaylistSource,
                                  resolver: any HMItemResolver,
                                  ranked: [HMMediaItem], nextPage: [HMMediaItem]) async {
    var config = HMPlayerConfiguration()
    config.volatileSigningQueryParameters = ["signature", "expires"] // Only names your origin declares volatile.
    let player = HMPlayer(configuration: config, resolver: resolver)
    let events = player.events // Subscribe before edits when their first event matters.
    let observation = Task { @MainActor in
        for await event in events {
            switch event {
            case .currentItemChanged(let item): print(item?.id ?? "idle")
            case .itemReady(let item): print(player.snapshot(for: item).readinessTier)
            case .error(_, let kind): print(kind.localizedDescription)
            default: break
            }
        }
    }
    defer { observation.cancel(); player.teardown() } // Terminal: use a new player afterwards.
    player.playlistSource = source
    await player.start()
    guard player.replaceAll(ranked, startAt: 0) else { return } // Empty accepts only startAt zero.
    guard player.reconcile(ranked) else { return } // Ranked refresh; preserves current/history.
    guard player.replaceUpcoming(nextPage) else { return }
    let hls = URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!
    guard player.insertNext([.init(id: "inserted", url: hls, format: .hls)]) else { return }
    guard player.append([.init(id: "appended", url: hls, format: .hls)]) else { return }
    await player.loadNextPage() // Nonthrowing: read loadError and error/duplicate events.
    player.jump(toID: "inserted") // Also explicitly retries remembered failures.
    player.play(); player.pause(); player.seek(to: 0); player.isMuted = true
    player.configuration.removedCurrentPolicy = .finishThenAdvance
    player.remove(ids: ["inserted"]) // Keep this visit until one natural end; swipe removes it.
    player.configuration.removedCurrentPolicy = .advanceNow // Default: next, previous, then idle.
    player.remove(ids: ["appended"])
    let current = player.currentItem
    let readiness = player.snapshot.readinessTier
    let change = player.lastPlaylistChange
    print(current?.id ?? "idle", readiness, change?.releasedPlayerCount ?? 0, player.loadError ?? "")
    player.isFeedVisible = false // Temporary hide; preserve owner and useful state.
    player.isFeedVisible = true
    player.replaceAll([]) // Explicit clear.
}
```

The player and analytics/source pushes run on MainActor. Sources and resolvers are Sendable and should cooperate with cancellation. Each event consumer owns its task cancellation. Coalesced resolver waiters cancel independently; completion is token-owned, and format promotion cannot be discarded by a metadata-only waiter. Explicit volatile-query configuration is safe-by-default (empty); other query parameters remain media identity. This normalizes identity and does not regenerate expired signed child URLs. Keep URLs valid for an active visit or implement renewal in the adapter/backend; Connect still uses vodURL/.auto.
