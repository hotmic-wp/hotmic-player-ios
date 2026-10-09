# Engagement and custom sources

Connect the overlay to the same headless engagement data your own views can use.

## Supply data

Create `HMPlayer(interactions: yourSource)` on the main actor. Implement the main-actor `HMInteractionSource` protocol from HotMicPlayer. `timeline(for:)` is required and must not open a session. The current-plus-next lifecycle hooks open, promote and close sessions. Declare supported actions with `capabilities(for:)`; otherwise components remain display-only.

The [complete source guide](https://github.com/hotmic-wp/hotmic-player-sdk/blob/main/Sources/HotMicPlayer/HotMicPlayer.docc/EngagementAndCustomSources.md) explains timeline offsets, server-ID adoption, echoes, ownership and moderation. [MemorySource.swift](https://github.com/hotmic-wp/hotmic-player-sdk/blob/main/Examples/PlayerWithUI/PlayerWithUI/MemorySource.swift) demonstrates a local source with no network or SPI.

## Components and clocks

| Component | Data and behavior |
| --- | --- |
| `HMChatRail` | Messages behind the playhead, with viewer reaction selection. |
| `HMPollCard` | Open polls and lingering results; votes only with `.vote` capability. |
| `HMFloatingReactions` | Media-clock stream reactions; respects Reduce Motion. |
| `HMActionRail` | Capability-gated reaction/comment controls; optional share and mute bindings. |
| `HMComposer` | Optimistic chat, preserving input on failure and exposing an inline error. |
| `HMEngagementScrubber` | Density, peak seek targets and current playback progress. |

Pass `context.mediaTime` or `snapshot.currentTime`, not wall time. Scrubbing backward replays the conversation at that offset. Chat `rowID` provides stable UI identity when a pending message gets a server ID.

Push source changes with `receive`, `upsertPoll`, and `updateReactions` from callbacks on the main actor, outside view bodies. Queries do not mutate observed state. Keep engagements weakly in your source; the player owns the source and caches engagements near the playhead.

## Moderation in UI

Message, stream-reaction and poll deletions survive engagement eviction for the item's playlist lifetime. Use `updateReactions(_:forMessage:)` for durable authoritative message counts. Message-reaction removal by count is an instance-local delta and must be delivered once. Removed poll IDs ignore subsequent upserts.

Per-item record overflow hides engagement and emits a unified-log error under `com.hotmic.player` / `moderation`. Operators should investigate the item ID in that log; records reset on playlist removal or teardown. The source guide documents the bounds and retained payload accounting.
