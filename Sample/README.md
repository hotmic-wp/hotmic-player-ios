# HotMicPlayer Sample

The full SwiftUI demo includes a vertical feed with `HMOverlayLayout`, in-memory engagement, playlist and reference labs, and benchmark controls. It intentionally uses Benchmark SPI. For smaller integrations using only public API, start with [PlayerOnly](../Examples/PlayerOnly) or [PlayerWithUI](../Examples/PlayerWithUI).

Open `HotMicPlayerDemo.xcodeproj`, select **HotMicPlayerDemo**, and run on an iPhone simulator. The default feed streams public test media and needs an internet connection. No video or poster is bundled in the repository. For benchmark origin setup, fixtures, launch options and result analysis, see [Benchmarking](../docs/BENCHMARKING.md).

## Default media and attribution

Both entries use **Big Buck Bunny**, © copyright 2008, Blender Foundation / [www.bigbuckbunny.org](https://www.bigbuckbunny.org/), under [Creative Commons Attribution 3.0](https://creativecommons.org/licenses/by/3.0/). See the project's [licence and attribution instructions](https://peach.blender.org/about/) and [Creative Commons' announcement](https://creativecommons.org/2008/06/13/big-buck-bunny-beautiful-cc-licensed-3d-short/). The credit is also shown in the demo's author line. The HLS rendition retains the movie's credits; the MP4 is a trimmed, resized and compressed excerpt. HotMic has made no further edits to either hosted file.

| Entry | Source URL | Licence |
| --- | --- | --- |
| MP4, 10-second 720p excerpt, hosted by Test Videos | https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/720/Big_Buck_Bunny_720_10s_1MB.mp4 | CC BY 3.0; attribution above |
| Adaptive HLS, hosted by Mux for hls.js | https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8 | CC BY 3.0; attribution above |

Mux identifies the rendition on its [test stream index](https://test-streams.mux.dev/). These are landscape open-movie test assets in the vertical feed. Public hosts may change or become unavailable; they are demo sources, not a playback service guarantee. No third-party poster is used by default.

## Local media and manifest overrides

Put your own `*.mp4` files in **`Sample/LocalMedia/`**, with optional same-name `*.jpg` posters. This folder is gitignored. Rebuild the Sample: its build phase copies only these files into the app's `LocalMedia` directory, and removes stale copies on every build. Any MP4s there replace the remote defaults, ordered by filename. Removing or emptying the folder and rebuilding restores the remote feed. Local media are embedded in that developer's app build; do not distribute builds containing content you lack permission to share.

Alternatively, set the **`HOTMIC_DEMO_MEDIA_URL`** environment variable in the Xcode scheme, or add launch arguments `--HOTMIC_DEMO_MEDIA_URL https://media.example.com/demo.json`. The single-dash spelling and `--HOTMIC_DEMO_MEDIA_URL=URL` also work. Arguments take precedence over the environment. A manifest overrides local files and remote defaults. It must be a nonempty JSON array with unique, nonempty IDs:

```json
[
  {"id": "one", "url": "one.mp4", "poster": "one.jpg", "title": "My clip", "author": "My credit", "duration": 12, "format": "mp4"},
  {"id": "two", "url": "two/index.m3u8", "title": "My HLS stream", "format": "hls"}
]
```

Only `id` and `url` are required. `format` is `mp4` or `hls`, inferred from `.m3u8` when omitted. `duration`, when supplied, must be positive seconds. Media and poster URLs resolve relative to the manifest. HTTP/HTTPS manifests are supported; use HTTPS for public sources. A `file://` manifest and relative local files also work when accessible inside the app sandbox (a simulator cannot assume arbitrary host-file access). Invalid manifests display an error instead of silently playing other content. Supply attribution for your chosen media in `author`.

An explicit benchmark grid or `--hm-manifest-url` retains its existing behavior and takes precedence over these demo overrides. The separate playlist/reference labs use the local folder or remote defaults.

## Local benchmark networking

The Sample's **Debug-only** `NSAllowsLocalNetworking` exception in `Debug-Info.plist` permits HTTP connections to local benchmark origins. It supports simulator loopback and local-network fixture servers during development. It is not a requirement for partner apps or an exception supplied by the SDK. Release builds omit this exception; use HTTPS for remote or public benchmark origins.

Select a device for compilation without setting up signing:

```bash
xcodebuild build -project Sample/HotMicPlayerDemo.xcodeproj -scheme HotMicPlayerDemo \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

Run the command from the repository root. Installation on a physical device requires your normal development signing and device setup.

## Ranked feed lab

Open Playlist lab and enable **Ranked feed refresh (3s, finish once)** after setting a local fixture origin. The origin must serve `item-0/clip.mp4` through `item-7/clip.mp4` (the adaptive smoke fixture generator creates these). Launch with `--hm-playlist-lab 1 --hm-ranked-refresh 1 --hm-lab-origin URL` to enable it automatically. Swipe above the controls while identical replacements, metadata refreshes and tail re-ranking run every three seconds. The scripted removal near the end seeks to the final second, then waits for the real media-end notification with looping enabled; a later removal leaves via an animated page move. Diagnostics record assignment generations, warm tiers, edit releases and playback events under Documents. The sequence ends after twelve refreshes; disable/re-enable the toggle to restart.

For extended local ranked-refresh diagnostics, launch the Playlist lab with `--hm-ranked-refresh 1 --hm-review-refresh 1`. It also re-signs a configured query, changes visible current, reconciles empty/history-only feeds, and removes already-ended or failed current entries. Operation logs include native assignment generations (seeks do not change them), states and edit summaries.

## Horizontal video lab

`--hm-horizontal-lab 1 --hm-manifest-url http://127.0.0.1:18490/mixed-orientation.json` opens `HorizontalLabScreen`, showing vertical/landscape MP4 and HLS, policy controls, video-frame bounds, fullscreen and an Inline/Feed switch. Add `--hm-horizontal-inline 1` to start at 16:9 inline. The Sample allows portrait and both landscape orientations. See [Horizontal video](../Sources/HotMicPlayer/HotMicPlayer.docc/HorizontalVideo.md) for the public SwiftUI/UIKit paths.

The Debug-only Documents control file `horizontal-command.txt` accepts `action|unique-nonce`, with actions `enter`, `exit`, `inline`, `feed`, `next`, `previous`, and policy raw values, for simulator captures while preserving playback. `horizontal-state.json` records current node assignment, activation, playhead, TTFF and stall count; `horizontal-lab.jsonl` records analytics in Documents. These are local Sample diagnostics.

## Host-built social layout

Open **Social layout** or launch with `--hm-social-layout 1`. This screen uses public HotMicPlayer API for persistent bottom nav, full-bleed video, metadata, rail, Fire at a tap location and an interactive comment sheet. Tap empty video to pause/resume, double tap to Fire, tap Comments and drag the sheet handle. Debug-only `--hm-social-trace 1` enables `social-layout.jsonl` in Documents with public analytics identity, first frames, stalls and playhead. Recording is off by default. Use `--hm-social-fixture 1` for generated offline media and the always-runnable gesture UI test. See [Building your own overlay](../Sources/HotMicPlayer/HotMicPlayer.docc/BuildingYourOwnOverlay.md).

## Ads lab

Open **Ads lab** or launch with `--hm-ads-lab 1`. All media are generated offline. The four entries demonstrate a six-second landscape URL pre-roll, a six-second colored host-played break with countdown, a slow decision that times out after one second, and content without an ad. The host overlay hides Comments, its preview and the squeezeback trigger while `adState.isActive`; Skip ad calls `skipAd()`.

Use `--hm-ads-inline 1` for standalone, `--hm-start-index 1` to start with the host break, or `--hm-ads-block-swipe 1` to disable pre-roll paging. The Feed/Standalone switch keeps the same player. Debug-only Documents diagnostics are `ads-events.jsonl`, `ads-state.json` and `ads-command.txt` (`action|unique-nonce`, actions: `swipe`, `next`, `skip`, `pause`, `play`, `feed`, `standalone`). The state records content's zero playhead and retained assignments during ads, plus content readiness and TTFF afterwards. See [Ads](../Sources/HotMicPlayer/HotMicPlayer.docc/Ads.md) for integration ownership and timeout details.

## Captions, audio and accessibility lab

Generate twelve seconds of synthetic video/audio plus English/Spanish WebVTT (requires ffmpeg). No remote media is downloaded:

```sh
python3 bench/prepare_captions_smoke.py
python3 bench/origin.py --root bench/generated/captions --port 18433 --log bench/results/captions-origin.jsonl
```

Open **Captions + audio** or launch with `--hm-accessibility-lab 1 --hm-captions 1`. MP4 uses bundled `bench.en.vtt`; HLS uses a real subtitle rendition discovered through AVMediaSelection. Toggle CC, choose English, swipe, and inspect the caption above the registered metadata/rail. Omit `--hm-captions 1` to follow the platform CC setting. Use `--hm-lab-origin URL` for another owned fixture origin. `--hm-host-audio 1` disables SDK session management; `--hm-background-audio 1` opts into background playback policy (the Sample does not enable an Audio background mode).

Debug-only Documents files: `caption-state.json` includes timing, caption preferences/languages, caption bounds and native accessibility labels/values/custom actions; `caption-events.jsonl` records ordered player events. Write `action|unique-nonce` to `caption-command.txt`: `cc`, `system`, `system-on`, `system-off`, `swipe`, `next`, `previous`, `pause`, `play`, `began`, `ended`, `ended-no-resume`, `route`, `background`, `foreground`, `reset`, `a11y-pause`, `a11y-mute`, `a11y-cc`, `a11y-increment`, `a11y-decrement`. System commands change the dedicated simulator's MediaAccessibility preference for validation; restore its original value afterwards. The in-memory original is restored when the lab is normally dismissed. Synthetic audio notifications test the handler, rather than actual telephony/hardware.

For paired S3 MP4/HLS binge smoke (CC off/on, six settled swipes each), start a loopback results receiver and launch with `--hm-grid-url http://127.0.0.1:18433/grid.json`:

```sh
python3 bench/results_receiver.py --host 127.0.0.1 --port 18435 --output bench/results/captions
```

The benchmark manifest accepts `"captions": {"en": "relative/file.vtt"}` and a grid cell can set `"knobs": {"captions": 1}`. These runs are simulator smoke evidence, not physical-device latency measurements.
