# Custom engagement backend

Copy `CustomEngagementBackend.swift` into your app target, link `HotMicPlayer`, and replace `FakeRESTClient` with your REST transport. The Sample compiles this exact file, so the example stays exercised without adding a library product.

```swift
let source = CustomEngagementBackend()
let player = HMPlayer(interactions: source)
// After supplying the playlist:
let engagement = player.engagement(for: item)
try await engagement.loadComments()
let preview = engagement.previewComment(rotation: rotationIndex)
let fire = engagement.reactionSummary(for: "🔥")
try await engagement.toggleReaction("🔥")
try await engagement.sendChat("What a play!")
try await engagement.loadComments() // Next older page, until olderCommentsCursor is nil.
```

The REST-shaped client isolates state by item ID and uses stable comment IDs and opaque older cursors. An unknown or deleted cursor throws instead of silently restarting pagination. Fire uses an idempotent PUT of desired membership, with an authoritative `{count, reactedByViewer}` response. `HMEngagement` applies the optimistic change, retains the latest wanted membership while a request is pending, and rolls back on error. `failNextRequest` fails before any mutation; set `latency` to inspect pending state. Throw from your transport on failure. Posting uses the existing `sendChat` action, preserving local row identity through server confirmation.

`engagementDidLoad` seeds cached metadata and retains engagements weakly. For a real service, start asynchronous metadata/session requests in `didBecomeCurrent`/`willBecomeNext`, cancel them in `didLeave`, and deliver updates on the main actor. Rehydrate metadata whenever an engagement is recreated. Keep credentials and network configuration in the host client.

Item comment pages do not enter the media timeline. For VOD replay, continue implementing a clock-indexed `HMStreamTimeline` and feeding `receive(_:)`; `messages(near:)` retains its timing contract. The Sample's fake Connect source demonstrates both kinds of data. It is an offline stand-in, not an implementation of the Connect package.

Open the Sample's Social layout screen to switch **Host backend** / **Fake Connect**, rotate preview comments, toggle fire from the rail or add fire with a double tap, open the sheet, load older comments and post. **Fail next** arms one client failure, allowing fire and posting rollback to be inspected. Counts use `HMCountFormatter`.
