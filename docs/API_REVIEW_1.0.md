# API review for 1.0.0-rc.1

Reviewed the complete `docs/PUBLIC_API.md` inventory, source declarations and behavior against 0.4.1, with 0.4.0 as the compatibility reference. The candidate keeps the two-product split: HotMicPlayer for playback/data and HotMicPlayerUI for optional iOS rendering. HotMicPlayerConnect remains a [separate adapter package](https://github.com/hotmic-wp/hotmic-player-connect-ios).

## Compatibility decisions

**No breaking public API changes from 0.4.0, and no new removals or renames in this candidate.** All existing partner declarations remain available. The 0.4.1 moderation methods are additive: `removeMessage(id:)`, `upsertPoll(_:)`, `removePoll(id:)`, stream-reaction removal by ID and message-reaction removal by count.

The one rename since 0.4.0 is `HMEngagement.update(_:)` → `upsertPoll(_:)`, introduced in 0.4.1. The old spelling still forwards and has `@available(*, deprecated, renamed: "upsertPoll(_:)")`, preserving source compatibility and a compiler fix-it. Partners should adopt the clearer poll-specific verb. No other rename needs a migration shim.

The candidate changes moderation behavior intentionally: shared projections update at mutation time rather than first query, and authoritative reaction totals now survive engagement eviction. It adds an overflow diagnostic. No playback, prefetch, retry or failed-item defaults changed.

## Surface and naming

- Keep the `HM` prefix on partner types. `HotMicPlayer` remains the existing namespace/version marker. SwiftUI environment/modifier names remain lowercase `hm…` by Swift convention. Nested `Options`, `Colors`, `Fonts` and `Icons` need no repeated prefix.
- Keep established labels and overloads: `replaceAll(_:startAt:)`, `remove(ids:)`, `seek(to:)` / `seek(toProgress:)`, `jump(toID:)`, and media-clock versus message-target `react` overloads. `posterURL` on items and `poster` on resolved values/factory inputs are retained for compatibility; a cosmetic rename would add migration cost without changing meaning.
- Keep synchronous atomic playlist edits returning `Bool` plus player error events. Transport controls do not start throwing. Resolver/paging adapters and engagement actions remain `async throws`; `start()` / `loadNextPage()` report errors in observed state/events. Returning nil from confirmed-event source methods keeps local identity.
- Keep analytics hub/sinks and the host-supplied Mux bridge public: they are real integration points. Keep `HMPageTransition.Attributes` / `attributes(offset:height:)` as established rendering customization, rather than silently retracting them. Keep `HMStaticPlaylistSource` as a useful deterministic, backend-free paging source.
- Engine nodes/pools, cache transport, audio session helpers, timeline aggregation and moderation implementation remain internal. Mock interaction/timeline providers, strategies, experimental thresholds, JSONL, detailed policy telemetry and benchmark controls remain Benchmark SPI. None are newly promoted into the stable contract. No partner symbol required new SPI restriction.
- Snapshot/state setters remain internal or private where already restricted. Generated declaration fragments can omit setter restrictions; source and compiled access control remain authoritative. A textual comparison with 0.4.0 shows `reactionTotals` and `revision` changing from `{ get set }` fragments to `{ get }`; both setters were already `private(set)` in 0.4.0 source, so this is not a removed partner setter.

## Isolation and ownership

`HMPlayer`, `HMEngagement`, `HMInteractionSource`, `HMStreamTimeline` and analytics objects are main-actor isolated. SwiftUI views and layout contexts use main-actor isolation through their view/layout contracts. Each exported declaration documents its threading; explicit view bodies now have their own comments rather than inheriting generic SwiftUI documentation.

Media, configuration, event, poll, chat, prefetch and resolver/page value contracts remain `Sendable`. `HMItemResolver`, `HMPlaylistSource` and `HMPrefetchPolicyProviding` remain `Sendable` protocols; mutable implementations must synchronize state. No `@unchecked Sendable` escape hatch was added. Theme/options configure SwiftUI on the main actor and do not promise cross-task transfer. Callbacks execute from main-actor views.

The moderation store's immutable limit constants are explicitly nonisolated, making default-argument evaluation valid without actor warnings. This is an internal annotation, not a partner signature change. Public API keeps the established package Swift 5 language mode with Swift 6 tools; adopting Swift 6 language mode is a separate migration.

Each `events` access creates an independent ordered subscription, newest-256 buffering, released by consumer cancellation. The player retains the source; player-created engagements borrow it, and source references to engagements must be weak. Standalone engagements retain their source. `teardown()` is terminal. These lifetime contracts are now in DocC and partner examples.

## Carry-over moderation fixes

1. **Pure observed reads.** Removed synchronization from `polls`, `reactionTotals`, `authoredMoments`, `density`, `markers`, chat/reaction queries and the internal viewer-state getter. Shared moderation stores hold weak registrations and synchronously project changes into living engagements on the mutation path. Old engagements held by a source still update rebuilt ones immediately. Lazy waveform/local-event caches remain Observation-ignored; queries can fill those caches without mutating observed state.
2. **Durable authoritative counts.** `updateReactions(_:forMessage:)` stores nonnegative authoritative counts in player-owned bounded records. Reads overlay those totals on source events, including after eviction or before message arrival. Updates clear instance-local deltas and advance action rollback versions. `removeReaction(_:forMessage:count:isOwn:)` remains explicitly delta-only for that engagement instance; deliver each delta once and use authoritative totals for durable moderation. No individual message-reaction IDs are invented.
3. **Overflow diagnostics.** Bounds are shared across deletion IDs and authoritative count records: 4,096 stored IDs and 256 KiB of UTF-8 IDs/emoji keys plus integer payloads. Overflow hides engagement for the item lifetime and emits one unified-log error under `com.hotmic.player` / `moderation`, including item ID, limits and recovery lifetime. Removed content is never restored by discarding old tombstones. No chat text is logged.

The existing parameterized moderation test now checks authoritative-count persistence across shared rebuild, continued instance-local delta behavior and updates through an older engagement. Existing deletion, pending-action, overflow and eviction coverage remains. No new test suite or redundant per-member tests were added.

## Documentation and release contract

The two DocC catalogs cover each integration level, playlist editing, performance/benchmark interpretation, engagement/custom sources and theming. Strict `xcodebuild docbuild` uses `--warnings-as-errors --analyze`; the symbol-graph exporter independently rejects any undocumented explicit non-SPI public symbol. The compiled Examples enforce ordinary public imports, and the partner Sample also uses public imports. Native UI regression diagnostics are isolated in DEBUG test support.

The README documents final-release SPM selection and exact candidate selection, requirements, support and semantic versioning. From 1.0, public non-SPI API follows semver; renames preserve deprecated forwarding entry points. Benchmark SPI/private implementation and demo tooling are excluded. New cases may arrive in minor releases of non-frozen public enums. Consumers should use `@unknown default` in switches to remain compatible.

## Optional diagnostics compatibility

`HMPlayerDiagnosticsConfiguration` and `HMPlayer.setDiagnostics(_:)` add host-controlled aggregate collection independently of playback configuration. The original four-argument initializer and its defaults remain exact, preserving typed initializer function references as well as existing calls. A separate convenience overload requires an explicit optional `diagnostics:` argument; ordinary construction stays off. Existing partner analytics dispatch is unchanged; the existing internal first-moving hook is recorded without adding partner events. See [the contract](../Sources/HotMicPlayer/HotMicPlayer.docc/OptionalDiagnostics.md).
