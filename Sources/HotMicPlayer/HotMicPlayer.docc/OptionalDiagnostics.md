# Optional aggregate diagnostics

Diagnostics are completely off unless the host enables them. URL playback needs no HotMic account; diagnostic delivery separately needs a Platform app key and the HTTPS base URL for its tenant. Obtain those from your Platform contact. Confirm tenant endpoint availability before a pilot; SDK source publication does not configure host enablement or prove valid live aggregate storage. The 1.0.0 aggregate reports SDK version `1.0.0` with schema version 1. Collector availability and host enablement are separate from SDK installation.

```swift
// Main actor. Use your Platform base URL and app key, never a viewer JWT.
let diagnostics = HMPlayerDiagnosticsConfiguration(
    baseURL: URL(string: "https://api.example.com")!,
    appKey: "YOUR_PLATFORM_APP_KEY", samplingPercent: 1)
player.setDiagnostics(diagnostics)
// Immediate cancellation, counter discard and timer removal:
player.setDiagnostics(nil)
// An explicit overload also accepts the policy; ordinary HMPlayer() remains off.
let anotherPlayer = HMPlayer(diagnostics: diagnostics)
anotherPlayer.teardown()
```

The same optional policy can be supplied as `HMPlayer(diagnostics: diagnostics)`. The original four-argument initializer signature and defaults remain intact, including typed factory references. The convenience overload requires an explicit `diagnostics:` argument. Changing diagnostics does not resize players, rebuild the queue or reset preparation. The host owns permission, disclosure and when to enable/disable it. Keep ordinary demos off; see the explicit [local walkthrough](https://github.com/hotmic-wp/hotmic-player-ios/blob/main/Sample/TestSupportTools/Diagnostics.md).

## Expendable delivery

The default enabled policy selects 1% of player lifetimes, without any identity. `samplingPercent` accepts 0–100%; zero, nonfinite/out-of-range values and unrepresentably tiny rates below 0.0001% disable collection. One random draw is reused during that player's lifetime; changing policies does not reroll it. Unsampled players create no accumulator, timer or diagnostic session.

A selected player owns one fixed-size numeric accumulator and eight fixed timing buckets. Logical windows cover at most 60 seconds; late events are excluded even if the timer wakes late. Normal timer jitter caps reported duration at 60000ms. A one-shot close is rearmed for at least 60 seconds after both the previous close and actual utility-side request admission; the small scheduling gap is unobserved, rather than merged into either window. Admission independently enforces the 60-second attempt cadence. Wakes delayed by two intervals (120 seconds) discard the window. No catch-up, merge, backlog or replay occurs. Performance-configuration changes discard the current window; unrepresentable settings or counter overflow discard it too.

There is at most one small application upload attempt per 60 seconds, including after failure and disable/re-enable, at most one pending encoding job/request, an 8192-byte wire-body cap and a two-second request/resource timeout target. Windows are discarded when busy or under playback pressure: startup, rebuffer, touch/page settling/custom interaction, ads, hidden/background, low power or serious/critical thermal state. Memory warnings discard the current window and cancel delivery. New startup/stall/interaction/ad pressure cancels existing delivery. The ephemeral session refuses constrained/expensive network access; no new network monitor is created. System networking may refuse or delay admission; there is no delivery guarantee.

Disable, hide, background and teardown cancel diagnostic delivery and discard counters. Returning visible/foreground starts a fresh window. There is no terminal flush, disk storage, persistent queue, retry, Retry-After handling or background upload. Network errors, redirects, authentication challenges, timeouts and all HTTP outcomes are terminal. Response delivery is cancelled at headers, including unexpected large/streaming error bodies. No acknowledgment body is accumulated. HTTPS uses system server trust; HTTP credential negotiation and redirects are refused. HTTP is allowed only for numeric loopback addresses in the local walkthrough.

## Fields and privacy

Version 1 sends only source-owned SDK version, numeric OS version, strict nonunique Apple hardware family (or simulator/unknown), sample rate, capped window duration, representable performance settings (content player count, configured startup bitrate preference (`startup_bps`, before adaptive plan adjustment), prefetch ahead/behind, hard per-entry byte/time budget, adaptive flag and lift/settle trigger), attempt/first-frame/end-before-frame counts, first-frame and first-moving timing histograms, and completed-stall count/duration. Warming, memory and byte summaries are omitted in this implementation. Stalls are counted at completion once; view-end summaries are not added again. First-moving uses the existing one-shot internal hook and adds no partner analytics event. Existing third-party analytics behavior remains unchanged.

Only numeric sanitized observations enter this accumulator. It never encodes playback events, event properties, custom dimensions, JSONL output, arbitrary error descriptions or fingerprints. No user/content/item/activation/player/session/install/device IDs, ID hashes, media text, URL/host/path/query/token, timestamps/raw uptime, errors/stacks, SSID/carrier/IP or device name/serial are sent. Requests use only the app-key authentication header, constant `HotMicPlayer` user agent and JSON headers, plus standard system HTTP transport headers (language is empty and encoding negotiation is fixed to identity); no viewer JWT, device ID, host cookies/credentials or host session headers. The server resolves the tenant from the app key.

These application records exclude IP and are not linked to a viewer or used for tracking. Network infrastructure still sees source IP: do not promise anonymous infrastructure. The bundled privacy manifest declares optional Performance Data and Other Diagnostic Data for analytics, unlinked and not tracking. Review your archive's privacy report and host App Store disclosures, consent requirements and independent analytics/ad/backend behavior. See Apple's [data-use declarations](https://developer.apple.com/documentation/bundleresources/describing-data-use-in-privacy-manifests) and [required-reason APIs](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api). Existing elapsed-duration use retains reason 35F9.1; raw boot time never leaves the device.

## Interpretation

Eight buckets are [0,100), [100,150), [150,250), [250,500), [500,1000), [1000,2000), [2000,5000), [5000,infinity) milliseconds. Percentiles inferred from them are approximate. Counts describe independently observed window events, not a linked per-user funnel: starts, first frames, moving playback and completed stalls can cross window boundaries. First-frame medians include only started/displayed views; always consider coverage and ended-before-frame counts.

Lifetime sampling, cancellation and pressure/error drops introduce selection bias toward windows that can be sent during comfortable playback. No stable viewer identifier links windows; the server adds tenant and receive time. These data do not establish universal performance guarantees. Compare with measured host-app coverage, data/memory and settling under the same content/network conditions; see <doc:PrefetchAndPerformance>.
