# Engagement and custom sources

Supply clock-indexed chat, reactions and polls without depending on HotMicCore.

## Source contract

``HMInteractionSource`` is main-actor isolated. Only `timeline(for:)` is required; all actions default to unsupported and capabilities default to read-only. Timeline construction must be cheap and must not start a network session. Lifecycle hooks operate on the current-plus-next window: `willBecomeNext`, `didBecomeCurrent`, then `didLeave` when an item loses both roles. Use those hooks to own sessions and cancel work.

Implement `capabilities(for:)` to expose `.sendChat`, `.reactToStream`, `.reactToMessage`, or `.vote`. The UI hides unavailable action controls. Provide polls once through `polls(for:)`; then push `upsertPoll(_:)` updates through a weakly held engagement received in `engagementDidLoad(_:)`.

```swift
@MainActor final class ReadOnlySource: HMInteractionSource {
    func timeline(for item: HMMediaItem) -> any HMStreamTimeline {
        ArchiveTimeline(duration: item.durationHint ?? 0)
    }
}
@MainActor final class ArchiveTimeline: HMStreamTimeline {
    let duration: TimeInterval
    init(duration: TimeInterval) { self.duration = duration }
    func events(in range: ClosedRange<TimeInterval>) -> [HMTimelineEvent] { [] }
    var density: [HMDensityBucket] { [] }
    var markers: [HMTimelineMarker] { [] }
}
```

The [PlayerWithUI Example](https://github.com/hotmic-wp/hotmic-player-sdk/tree/main/Examples/PlayerWithUI) includes a small writable in-memory source using only public API.

## Timeline and actions

All offsets are seconds on the item's media clock. Return sorted windows from `events(in:)` and precompute density and markers when data changes. `append(_:)` may be ignored for immutable history; the engagement retains accepted viewer events separately. Use `receive(_:)` for incoming events so aggregates and observed revision update together. Do not deliver source mutations from a SwiftUI body.

`sendChat` and stream `react` can return a confirmed event with a server ID, author and wall time. Nil keeps the local ID. The viewer's action offset remains local; chat `rowID` stays stable across server-ID adoption. Echoes with the same event ID are deduplicated. Throw to withdraw or roll back optimistic state. Poll votes and message reactions prevent duplicate viewer actions. Catch errors in host controls; the engagement also exposes `lastActionError`.

The player owns its source strongly. Player-created engagements borrow it weakly; source implementations must hold engagements weakly to avoid cycles. Standalone engagements retain their source. Engagements follow the prefetch window, except those holding viewer actions remain while their item is in the playlist.

## Moderation and durability

`removeMessage(id:)`, `removeReaction(id:)` for stream events, and `removePoll(id:)` create idempotent player-owned tombstones. Late echoes and poll upserts cannot restore deleted IDs. Removal records survive engagement eviction until the item leaves the playlist or the player tears down.

`updateReactions(_:forMessage:)` is the **durable** authoritative-count path. Counts include viewer reactions, are clamped at zero, and survive engagement eviction. It can arrive before the message. `removeReaction(_:forMessage:count:isOwn:)` is an instance-local delta: deliver each deletion once and send authoritative totals if it must survive eviction. It has no individual reaction ID for deduplication.

Records share a per-item bound of 4,096 stored IDs and 256 KiB of UTF-8 IDs, emoji keys and count payloads. Overflow hides that item's engagement for the rest of its playlist lifetime, preserving moderation safety. Operators can filter unified logs for subsystem `com.hotmic.player`, category `moderation`; one error logs the item ID, bounds and recovery lifetime. It does not include chat text.

Queries, including `polls`, `reactionTotals` and density, never synchronize or mutate observed state. Shared records notify living engagements synchronously on mutation. Waveform projection is cached outside Observation and rebuilt lazily when dirty. Source weighting is preserved when its events already exclude deletions; otherwise surviving events use SDK aggregation.

The former `update(_:)` poll spelling remains deprecated with `renamed: "upsertPoll(_:)"`.
