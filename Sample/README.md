# HotMicPlayer Sample

The full SwiftUI demo includes a vertical feed with `HMOverlayLayout`, in-memory engagement, playlist and reference labs, and benchmark controls. It intentionally uses Benchmark SPI. For smaller integrations using only public API, start with [PlayerOnly](../Examples/PlayerOnly) or [PlayerWithUI](../Examples/PlayerWithUI).

Open `HotMicPlayerDemo.xcodeproj`, select **HotMicPlayerDemo**, and run on an iPhone simulator. The bundled videos work without a backend. For benchmark origin setup, fixtures, launch options and result analysis, see [Benchmarking](../docs/BENCHMARKING.md).

## Local benchmark networking

The Sample's **Debug-only** `NSAllowsLocalNetworking` exception in `Debug-Info.plist` permits HTTP connections to local benchmark origins. It supports simulator loopback and local-network fixture servers during development. It is not a requirement for partner apps or an exception supplied by the SDK. Release builds omit this exception; use HTTPS for remote or public benchmark origins.

Select a device for compilation without setting up signing:

```bash
xcodebuild build -project Sample/HotMicPlayerDemo.xcodeproj -scheme HotMicPlayerDemo \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

Run the command from the repository root. Installation on a physical device requires your normal development signing and device setup.
