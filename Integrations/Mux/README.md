# Mux Data integration

HotMicPlayer ships **mocked**. `HMMuxAnalyticsSink` builds real Mux payloads and
hands them to an `HMMuxBridge`; the default bridge (`HMLoggingMuxBridge`) records
them instead of sending them, which is what the sample app's "Mux beacons" tab
renders.

Going live is two steps.

## 1. Add the dependency

```swift
// Package.swift
.package(url: "https://github.com/muxinc/mux-stats-sdk-avplayer", from: "4.0.0")
```

…and add `MUXSDKStats` to your app target's dependencies.

## 2. Swap the bridge

Copy `MuxDataBridge.swift.txt` into your app as `MuxDataBridge.swift`, then:

```swift
let sink = HMMuxAnalyticsSink(
    environment: HMMuxEnvironment(
        environmentKey: Secrets.muxEnvironmentKey,
        playerName: "HotMicVerticalFeed",
        viewerUserID: session.userID
    ),
    bridge: MuxDataBridge()          // instead of HMLoggingMuxBridge()
)
analytics.add(sink)
```

Nothing else changes. `HMFeedController` already calls
`attach` / `videoChange` / `detach` at the right moments.

## Why the bridge exists at all

A vertical feed recycles a small pool of `AVPlayer`s. Mux bills and reports per
**view**, and it keys views off the monitored player. The naive integration —
`monitorAVPlayerLayer` on cell appear, `destroyPlayer` on cell disappear — does
two harmful things at feed scroll speed:

1. It churns Mux's player registry several times a second.
2. It reports a fresh player rather than a new video on the same player, which
   loses the session continuity Mux uses for viewer-level metrics.

`HMMuxAnalyticsSink` tracks pooled players by key and calls
`videoChangeForPlayer` on a recycle, only calling `destroyPlayer` when the node
is genuinely released. That behaviour is visible in the sample app: swipe the
feed with the Mux beacons tab open and you will see one `monitorAVPlayerLayer`
per pool slot followed by a stream of `videoChangeForPlayer` calls.

## What the sink forwards, and what it doesn't

Mux's AVPlayer SDK derives play / pause / rebuffer / variant-switch / bitrate
directly from the `AVPlayer` it monitors. Forwarding HotMicPlayer's equivalents
would double-count, so the sink deliberately forwards only what Mux *cannot*
observe: view boundaries (`videoChange`) and errors (`dispatchError`).

The full normalised event stream is still available to every other sink — that's
what `HMConsoleSink` prints, and what you would point at an internal warehouse.
