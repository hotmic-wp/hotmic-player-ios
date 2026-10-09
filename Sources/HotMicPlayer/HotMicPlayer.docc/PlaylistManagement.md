# Playlist management

Edit the loaded playlist atomically without rebuilding the feed.

## Five operations

IDs must be nonempty and unique across the resulting playlist. All five calls are synchronous on the main actor and return a success Boolean. Invalid edits leave the previous playlist intact and emit ``HMPlayerEvent/error(item:kind:)``. Successful effective edits emit `playlistChanged` and, if necessary, `currentItemChanged`.

| Operation | Playback effect |
| --- | --- |
| `replaceAll(_:startAt:)` | Selects the supplied index and resets paging to a nil cursor. Empty with index zero becomes idle. |
| `replaceUpcoming(_:)` | Replaces every entry after current; keeps current clock, buffer and layer. |
| `insertNext(_:)` | Inserts immediately after current; creates a playlist when empty. |
| `append(_:)` | Adds to the end and preserves current playback. |
| `remove(ids:)` | Removes matching IDs; if current is removed, selects the next survivor, then previous, then idle. |

```swift
player.replaceAll([intro, replay], startAt: 0)
player.replaceUpcoming([replay, finale])
player.insertNext([sponsor])
player.append([bonus])
player.remove(ids: [sponsor.id])
```

Empty appends/inserts and removing unknown IDs are silent no-ops. During a swipe, an edit preserves the move unless the current or destination ID changes position. Appending does not interrupt a swipe. Item identity also scopes moderation: removing an item ends its retained records; re-inserting the same ID begins a new lifetime.

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

Default `.skip` tries the next nonfailed entry, then previous, then idle. `.stay` keeps the failed entry selected. Failed items remain in the playlist and are excluded from automatic traversal. Transient network failures retry current/next with bounded, jittered backoff. Skips wait for page motion and interactions to settle. Wrap custom scrubbers or menus with `beginInteraction()` / `endInteraction()`; a missing end expires after 30 seconds.
