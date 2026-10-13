# Benchmark provenance and current defaults

The [root README](../README.md#requirements-and-performance) is the public inventory of historical runs, supplied observations, unsuccessful/reverted work and pending device comparisons. Existing grids may override the current defaults (HLS examples, two players, fixed 3/1, 4 seconds/8 MiB, adaptive off, known-target lift); their presence is not evidence that they ran. Direct manual launches accept `--hm-activation-trigger lift` or `settle`, and grid cells accept `activation_trigger`; automated requestPage grids remain programmatic settled moves. Do not mix their clocks or infer a touch-lift benefit from a programmatic grid. Report attempted/started/never-started views and start coverage alongside first/swipe p50/p90, first frame/moving playback, stalls, bytes/reuse/memory/player count and animation settling. Physical comparisons on iPhone 16 Pro/iPhone 11 need at least three matched repeats; currently pending.

# Headless HotMicPlayer benchmarking

You can do content preparation, serving, shaping and analysis on **Linux**.
Get device builds from the manual macOS GitHub Actions workflow or a remote Mac
with Xcode. Once installed, benchmark mode runs unattended on **your own iPhone**
or **AWS Device Farm**, without Xcode or XCUITest on your Linux machine. A remote
Mac can also drive device/Simulator runs over SSH. The build and automation steps
are CLI-only; no Xcode GUI is required. Credible timing requires a physical iPhone.
Do not use production HotMic media or treat Simulator timings as benchmark numbers.

## Dependencies and ownership

Linux: Bash, Python 3.9+, FFmpeg/ffprobe with libx264 and AAC, Caddy 2 for the
TLS/HTTP2 origin, and `tc` from iproute2 for netem. Python is stdlib-only.
macOS: Xcode (tested with 26.5), its command-line tools, Bash, Python 3.9+,
FFmpeg/ffprobe for local encoding. The Python origin needs no additional packages.
Nothing here installs software. Provision missing tools through your normal
approved process. Use your own test devices, dedicated simulators
and a dedicated origin network interface. `netem.sh` changes
that interface's root qdisc; never run it on a shared or management network interface.

The package unit suite is `swift test`, separate from the benchmark XCUITest
scheme. The benchmark scripts are long-running tools and are not CI/merge tests.
No signing settings, distribution profiles, Fastlane or deployments are changed.
A physical-device build needs the remote Mac's **already provisioned development
signing** and trusted device. Without that, stop and have its owner prepare it.

## 1. Linux: encode your own source clips

Clone/check out the approved feature commit (or receive this repo over SSH).
Supply your own source clips with permission for your intended use; no source
videos or posters are bundled. For example, put MP4s in the ignored
`Sample/LocalMedia/` folder and run:

```bash
bench/encode.sh Sample/LocalMedia bench/generated https://bench.example.com 2
```

Arguments are source directory, output directory, origin base URL and keyframe
interval (1 or 2 seconds). Every clip is normalized to 30 fps (so the GOP is
`key*30` frames everywhere, `-sc_threshold 0`), 2-pass H.264 High + AAC 96k.
Rungs are named by the short side and **capped at the source**: a rung above the
source's short side is skipped, never upscaled, and the aspect ratio is kept
(no padding), so a 4:5 720x900 source gives 720x900/540x676/360x450 and a 16:9
source gives 1280x720 and below. Video bitrates: 1080 4.5 Mbps, 720 2.4, 540 1.2,
360 0.6 (maxrate 1.5x, bufsize 2x). Outputs per clip:

- `mp4-faststart-<rung>.mp4` for every rung; the 1080/720 ones are the MP4 sizes,
  540/360 are HLS sources (a sub-720 source's top rung is its only MP4 size).
- `mp4-no-faststart-<size>.mp4`: a `-c copy` remux of each MP4 size with `moov`
  after `mdat`, like the `hls-to-mp4` Lambda.
- `hls-2s/` and `hls-6s/`: fMP4 with 720/540/360 rungs (capped), each rung a
  remux of the matching MP4, independent segments, master lowest rung first,
  `BANDWIDTH` = measured peak segment bitrate.
- `poster.jpg` from the top MP4.

The output includes one JSON playlist per format (`mp4-faststart-720.json` only
lists clips that have a 720 rung; `mp4-faststart-top.json` has every clip at its
HLS top rung, the like-with-like MP4 set for HLS comparisons), `encoding.json`,
`manifest.json` (per clip and variant: bytes, sha256, resolution, keyframe
intervals and `moov` position verified with ffprobe/an atom walk; category and
length bucket when `CLIP_LIST=clip-list.json` is set, which also verifies source
checksums first) and `checksums.sha256`. The build fails if any variant's GOP or
`moov` position does not verify. `ENCODE_JOBS=4 ENCODE_THREADS=2` encodes four
clips at once. `HLS_AS_SERVED=list.txt` (lines `<id> <master-url>`) also mirrors
each clip's HLS as the CDN serves it, byte for byte, into `hls-as-served/`
(`bench/mirror_hls.py`); that baseline is recorded as found and exempt from the
GOP and cap rules. Validate checksums with `sha256sum -c checksums.sha256` on
Linux or `shasum -a 256 -c checksums.sha256` on macOS, from the output directory.
All generated media/results are gitignored. Each manifest has 80 distinct item
IDs cycling the source clips. That repetition exercises recycling and cache
reuse; it is **not** an 80-unique-video workload. For real benchmark conclusions,
provide enough distinct approved source content and regenerate manifests with
unique paths. Don't compare repeated-media smoke data against unique-media runs.

For quick local playback checks, `ENCODE_SECONDS=12 ENCODE_PRESET=ultrafast`
shortens every source consistently. Those encodes have different compression
characteristics and must be labeled smoke-only. Production runs should use the
same encoder settings, clips, GOP and checksums for every strategy.

## 2. Linux: origin and phone topology

For HTTPS and HTTP/2 with CDN-like cache headers and completed-request JSON logs:

```bash
BENCH_ROOT="$PWD/bench/generated" BENCH_HOST=bench.example.com \
BENCH_LOG="$PWD/bench/results/caddy.jsonl" caddy run --config bench/Caddyfile
```

Use a DNS name reaching this Linux machine and an existing trusted certificate
setup. Caddy can manage certificates where the server is reachable for ACME;
that is infrastructure setup by its owner, not a prerequisite needing the Xcode
GUI. `BENCH_HOST=:8088` runs plain LAN HTTP/1.1 instead. iOS uses HTTP/2 over TLS;
the zero-install fallback below is HTTP/1.1. Record which origin transport you
used rather than combining results.

For local Mac dev, or Linux smoke runs without Caddy:

```bash
python3 bench/origin.py --root bench/generated --host 0.0.0.0 \
  --port 8088 --log bench/results/origin.jsonl
```

This fallback supports single closed/open/suffix byte ranges, HEAD and 416, and
logs request range, payload bytes and elapsed time. Python's ordinary
`http.server` is **not** a substitute. Use `127.0.0.1` instead of `0.0.0.0` for
Simulator-only local access. For a phone, manifest URLs must contain the Linux
LAN hostname/IP, **not localhost**. Regenerate manifests with the LAN base URL.

Put the iPhone and Linux origin on the same Wi-Fi/LAN; the Mac may also be there
but only drives the phone. Media travels **phone -> Linux origin**, not through
the remote Mac. Shaping the Linux origin's egress NIC shapes response traffic
bound for the phone, including HLS and MP4. With a dedicated NIC:

```bash
sudo bench/netem.sh eth1 fair-4g
bench/netem.sh eth1 show
# After all runs:
sudo bench/netem.sh eth1 clear
```

Profiles are `lan`, `good-lte` (30 Mbps, +50ms RTT), `fair-4g` (5 Mbps, +100ms
RTT, 0.5% response packet loss), and `poor` (1.5 Mbps, +200ms RTT, 1% response
packet loss). TBF limits egress throughput, netem adds delay/loss. Only one leg
is shaped, so the delay is the full added RTT, on top of existing LAN latency.
A symmetric router setup should split delay between both legs. This is an
origin-side approximation: phone uplink, radio scheduling, real carrier jitter,
DNS and TLS handshakes differ from cellular networks. Confirm actual RTT/rate
from that phone; record active qdisc output alongside the run. A shared NIC
would also shape SSH and other users, so it is outside this workflow.

## 3. Linux: player-independent startup check

On an otherwise quiet origin, measure one representative file/playlist:

```bash
bench/lowerbound.sh https://bench.example.com/chiefs-1v1/mp4-faststart-720.mp4 \
  bench/results/caddy.jsonl bench/results/lowerbound-mp4
bench/lowerbound.sh https://bench.example.com/chiefs-1v1/hls-2s/master.m3u8 \
  bench/results/caddy.jsonl bench/results/lowerbound-hls
```

Repeat for every variant. The script writes ffprobe metadata separately, then
records the origin log delta for ffmpeg decoding exactly one video frame:
request count, received payload bytes and individual timing/ranges. FFmpeg reads
ahead (and a master HLS playlist may probe multiple variants), so this is a
**decoder-start check / upper estimate**, not a mathematical byte minimum or
AVPlayer TTFF. Use a rendition media playlist when isolating a specific rung.
Run on an idle origin because concurrent requests contaminate the log delta.
Origin completed-request logs count server-sent bytes, which may exceed bytes
received/used by a client that closes early.

## 4. Get a device build from Linux

A Linux-only tester can get both device artifacts from the single
**Build benchmark device artifacts** Actions workflow
(`.github/workflows/benchmark-build.yml`). It is **workflow_dispatch only**:
no push/PR/scheduled triggers, no tests, cloud runs or deployment. It builds the
Debug Sample app and XCTest runner for a generic iOS device on `macos-26`, with
`CODE_SIGNING_ALLOWED=NO`, within a ten-minute job limit. The workflow must be
available on the repository's default branch before GitHub can dispatch it;
dispatch it only when you intend to build benchmark artifacts.

An authorized operator can dispatch/download it with existing GitHub access:

```bash
gh workflow run benchmark-build.yml --ref main \
  -f grid_url=https://bench.example.com/grids/run.json
gh run list --workflow benchmark-build.yml
gh run download RUN_ID --dir bench/results/build
```

Artifacts are `hotmic-benchmark-ios-app/HotMicPlayerDemo.ipa` (a Payload/app IPA)
and `hotmic-benchmark-xctest-ui/HotMicPlayerDemoUITests.zip` (one Runner.app at the
zip root, no Payload folder). The optional `grid_url` input is included as a
`grid-url.txt` resource **before signing** in the XCTest bundle. The wrapper can
therefore find it even if Device Farm generates its own xctestrun file. Bundles
are device builds, never Simulator artifacts. `bench/package_device_farm.py`
packages existing products headlessly and verifies their device platform.

Unsigned artifacts are the default for **Device Farm public devices**, which
[AWS re-signs](https://docs.aws.amazon.com/devicefarm/latest/developerguide/skip-app-re-signing-on-private-devices.html).
They do not install directly onto your own iPhone. For your own phone, provide a valid development-signed IPA: the Apple development team and
certificate/private key (P12 and its password), an app provisioning profile
matching `com.hotmic.HotMicPlayerDemo`, the registered iPhone UDID, and a trusted
Developer Mode-enabled phone. For a locally installed XCTest runner, also provide a profile for `com.hotmic.HotMicPlayerDemoUITests.xctrunner`.
Certificates/profiles must be unexpired, from the same team, and cover that
phone. No existing project signing settings or signing secrets were changed.

The workflow's optional `sign=true` checks four **existing** repo secrets:
`IOS_DEV_CERTIFICATE_P12_BASE64`, `IOS_DEV_CERTIFICATE_PASSWORD`,
`IOS_APP_PROFILE_BASE64`, `IOS_RUNNER_PROFILE_BASE64`. If any of these inputs
are absent, signing skips cleanly and artifacts stay unsigned. When supplied,
it imports the certificate into an ephemeral runner keychain, embeds the
profiles, signs nested code and the two apps, and removes the keychain/files.
Your development team supplies these signing inputs through your approved
process. Private Device Farm pools have different signing/trust rules; follow
your configuration and AWS guidance.

For a remote Mac with an already prepared environment, the equivalent commands
are:

```bash
xcodebuild build-for-testing -project Sample/HotMicPlayerDemo.xcodeproj \
  -scheme HotMicPlayerDemo -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath .bench/DeviceFarm CODE_SIGNING_ALLOWED=NO \
  HM_BUILD_SHA="$(git rev-parse HEAD)"
python3 bench/package_device_farm.py \
  --products .bench/DeviceFarm/Build/Products/Debug-iphoneos \
  --output .bench/DeviceFarmArtifacts --grid-url https://bench.example.com/grid.json
```

A separate no-signing generic-device compile is:

```bash
xcodebuild build -project Sample/HotMicPlayerDemo.xcodeproj -scheme HotMicPlayerDemo \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath .bench/DeviceBuild CODE_SIGNING_ALLOWED=NO
```

## 5. Configure one grid and a result receiver

Copy `bench/grid.example.json`, set the origin/result URLs for your topology,
and serve it alongside the generated manifests. Each cell has an ID, strategy,
format label, playlist URL, script, repeats, optional swipe count (default 50),
optional dwell, and a map of numeric knobs. Relative playlist/result references
resolve against the grid URL. The whole grid's structure and knobs are validated
before the first run. Example:

```json
{
  "run_prefix": "iphone-grid",
  "network": "fair-4g",
  "results_url": "https://bench.example.com/runs",
  "cells": [
    {
      "id": "hybrid-hls-binge",
      "strategy": "S3",
      "format": "hls-2s",
      "playlist_url": "/hls-2s.json",
      "script": "binge",
      "repeats": 3,
      "swipes": 50,
      "reset_cache": true,
      "knobs": {"players": 2, "ahead": 5, "behind": 1,
                "prefetch-bytes": 800000, "threshold": 3,
                "cache-cap": 128000000, "startup-bitrate": 1600000}
    }
  ]
}
```

Start the stdlib receiver on Linux or macOS:

```bash
python3 bench/results_receiver.py --host 0.0.0.0 --port 8090 \
  --output bench/results/received
```

For Device Farm use a public HTTPS result URL, e.g. a Caddy `reverse_proxy` for
`/runs` to a receiver bound to 127.0.0.1:8090. The existing Caddy origin config
can be extended by its owner for this endpoint; no hosting is done by these
scripts. The receiver validates complete JSONL/run IDs and stores each POST
atomically. Identical retry uploads are accepted; conflicting run IDs get 409.
It caps request size (64 MiB default). Bind publicly only on an owner-approved
benchmark host, using the intended network controls; config URLs and results
contain test content, not credentials or production media.

The app creates a unique grid-session suffix, so repeat run IDs do not overwrite
past results. It POSTs every flushed JSONL with `application/x-ndjson` and
`X-HotMic-Run-ID`. **Every run keeps a local copy**, whether upload succeeds or
fails. Failed uploads increment a visible counter and the grid continues. An
invalid cell, missing page commit or decoder error stops the grid visibly, with
the partial run retained locally. The bench screen shows overall run/cell/repeat
progress, current item, final status, and a Share link for the last completed run.
Files sharing exposes `Documents/BenchRuns/` for all runs/partial files.

Scripts run in-app: `binge` (1s dwell), `normal` (5s), `watchThrough` (known clip
duration + .2s), `backAndForth` (alternate forward/back), and `jumpTo20` (start at
zero-based index 19, then forward). Each defaults to 50 page moves. Cells can set
`dwell_seconds`, `swipes`, `reset_cache` (default true), and `require_frame`
(default false). The last item also gets dwell. `require_frame=true` is for smoke
proof: it waits for every item to display before leaving. For adverse-network
benchmarks leave it false so skipped slow views remain censored in analysis.
Animation/settling adds to dwell; use actual page-commit timestamps for cadence.
The app disables idle sleep during a grid and restores it afterwards.

Autopilot calls `requestPage(at:)`, which animates the same paging scroll view.
Only the **same UIScrollView settled delegate callback** used by touch swipes
activates the new item and starts swipe TTFF. It does not call activation at the
start of the animation. Polling in the autopilot only waits for completion; the
measurement remains the event-driven SDK presentation detector.

## 6a. Own iPhone + Linux, without Xcode/XCUITest

Obtain the **device-signed** IPA from your development team or the optional signed workflow.
The Linux host needs usbmuxd/libimobiledevice and ideviceinstaller, provisioned
through its normal owner-approved process. Connect the registered, unlocked
phone by USB, trust the Linux host and enable Developer Mode if required. Then:

```bash
idevice_id -l
idevicepair -u PHONE_UDID pair
ideviceinstaller -u PHONE_UDID install HotMicPlayerDemo.ipa
```

Modern ideviceinstaller uses the `install` subcommand; older releases use
`-i HotMicPlayerDemo.ipa`. Check `ideviceinstaller --help` for your installed
version ([upstream CLI](https://github.com/libimobiledevice/ideviceinstaller/blob/master/man/ideviceinstaller.1)).
This command installs an **already signed** IPA; it cannot turn the unsigned
Device Farm artifact into a provisioned app. Device/iOS support depends on the
installed libimobiledevice version, so installation/trust on a current iPhone
still needs validation by its owner.

Open HotMicPlayerDemo on the phone, tap **Benchmark mode**, paste the grid URL
and tap **Run grid**. The URL is remembered for next time. Approve the app's LAN
network permission once for an HTTP LAN run. It fetches the grid, runs all cells
unattended and uploads results. Leave the app foregrounded and the phone in a
consistent thermal/power state. There is no Mac dependency for this run or its
analysis. If upload fails, retrieve JSONLs from Files > HotMicPlayerDemo >
BenchRuns or Share, and analyze them on Linux.

## 6b. AWS Device Farm, without owning a phone/Mac

Download the unsigned artifacts from the manual Actions workflow. The owner
uploads the app IPA as `IOS_APP` and the test ZIP as `XCTEST_UI_TEST_PACKAGE` to
your Device Farm project/device pool. The [AWS package guide](https://docs.aws.amazon.com/devicefarm/latest/developerguide/test-types-ios-xctest-ui.html)
describes the IPA and single Runner.app ZIP layouts. Linux AWS CLI uploads and
run scheduling are possible using the owner's existing AWS access; this task
does not create cloud runs, credentials, projects or deployments.

Use the workflow `grid_url` input to bundle a **public HTTPS grid URL** in the
wrapper. The wrapper opens the bench screen, enters that URL and waits for the
same in-app grid. Alternatively, a custom Device Farm test specification can
inject `HM_GRID_URL` into the test runner environment. The wrapper fails on an
app-reported grid error, waits up to `HM_GRID_TIMEOUT` (default 7200s), and takes
a final screenshot. `HM_REQUIRE_UPLOAD=1` makes upload failures fail the wrapper.
It owns no separate swipe logic. Set Device Farm's job/test timeout to cover the
grid; split long watchThrough grids into smaller jobs. The wrapper skips with a
clear reason if neither an environment URL nor bundled URL was provided.

Device Farm cannot access a private LAN origin/results receiver. Use a public
HTTPS origin/receiver, or an owner-prepared network path. Its WAN baseline RTT
is different from a phone on your Wi-Fi; record it. Origin-side netem still
adds delay/loss/rate limits to response traffic, but does not simulate the
phone's radio. Do not compare a Device Farm result labeled fair-4g against a LAN
result with a different baseline RTT without reporting that difference. Public
Device Farm re-signing, bundle installation, local-network consent and result
POSTs have **not** been proven by Simulator smoke runs.

## 6c. Remote Mac / Simulator automation

Build for a dedicated iPhone simulator, then launch the thin wrapper:

```bash
xcodebuild build-for-testing -project Sample/HotMicPlayerDemo.xcodeproj \
  -scheme HotMicPlayerDemo -configuration Debug -destination 'id=SIM_UDID' \
  -derivedDataPath .bench/SimulatorTests CODE_SIGNING_ALLOWED=NO \
  HM_BUILD_SHA="$(git rev-parse HEAD)"
python3 bench/run.py \
  --xctestrun .bench/SimulatorTests/Build/Products/HotMicPlayerDemo_iphonesimulator26.5-arm64.xctestrun \
  --destination SIM_UDID --simulator --set HM_RUN_ID=wrapper-grid \
  --set HM_GRID_URL=http://127.0.0.1:8088/smoke-grid.json --set HM_REQUIRE_UPLOAD=1
```

For a provisioned physical phone, build using its already prepared development
signing and `-destination id=UDID`, then omit `--simulator`. `run.py` invokes
`xcodebuild test-without-building -destination id=UDID`, injecting the environment
into a copied xctestrun beside the original (preserving `__TESTROOT__`). It pulls
Simulator files with simctl, phone files with devicectl, and records wrapper wall
time. It is callable over SSH from Linux. `xcodebuild test -project ... -scheme
... -destination id=UDID` is also supported when a grid URL is bundled/provided.

For the 16-cell Simulator smoke matrix (S0/S1/S2 with four players/S3 × MP4
faststart 720/HLS 2s × normal/binge, 50 moves each), copy
`bench/grid.smoke.json` into the origin root as `smoke-grid.json`. It uses
localhost and `require_frame=true`; change URLs for a phone and do not use this
frame-waiting smoke grid for adverse-network performance conclusions. Allow sufficient time for the entire matrix; record the fixture duration,
frame-wait policy and shaping profile alongside your results.

## Grid knobs and direct launch arguments

Grid `knobs` use the names below as numeric JSON values; a strategy is a preset,
then every supplied knob overrides it. Direct single-playlist demo launches still
accept `--hm-name value` or `HM_NAME=value`, with arguments taking precedence.
Grid runs take their playback knobs from cells, not unrelated launch overrides.

| Grid knob | Meaning / S3 default |
| --- | --- |
| `players` | Live allocation 1–4, default 2 |
| `ahead`, `behind` | Data window 0–8 per side, default 3/1; S2 warm window |
| `prefetch-bytes` | Response-payload budget/item, default/max 8388608 (8 MiB), aggregate speculative payload, 512 KiB chunks |
| `prefetch-seconds` | Default 4-second target; optional time budget, byte cap retained; MP4 estimate, HLS segment selection |
| `threshold` | Current seconds ahead before speculation (default 3), or fully buffered short remainder |
| `cache-cap` | Hard disk bytes cap, default 128000000 |
| `startup-bitrate`, `startup-window` | Initial bps ceiling (1600000, zero uncapped), duration 4s |
| `steady-bitrate`, `steady-buffer`, `warm-buffer` | Post-start ceiling 0, active buffer 10s, paused buffer 3s |

`--hm-grid-url` / `HM_GRID_URL` auto-starts benchmark mode. Direct launch knobs
also include `--hm-manifest-url`, strategy/players/ahead/behind and the same knob
names above; `--hm-format`, `--hm-network`, `--hm-run-id`, `--hm-script`,
`--hm-auto-start 1`, `--hm-start-index` (zero-based), `--hm-build-sha`, and
`--hm-reset-cache 1`. Numeric invalids stop visibly. The Sample's public remote
MP4/HLS demo feed is the default when no manifest/grid is supplied; optional local
media and demo manifests are described in [Sample](../Sample/README.md).
The last typed grid URL is remembered
in app preferences. No configuration or result URL is compiled into the SDK.

S0/S2 do not read/write disk cache. S0/S1 allocate no warm neighbours; additional
player allocations stay idle when that strategy does not use them. S2 is the
old competing warm-pool path; S3 warms at most players minus one. Default S3 uses
two players. Cold grids clear cache before **every repeat**; set reset_cache=false
only for explicit warm-disk experiments and report that dimension.

HTTP LAN exceptions belong **only to the Sample Debug Info.plist**, using
NSAllowsLocalNetworking. Release and the SDK add no LAN ATS exceptions.
Debug bench builds may be device-signed or Device Farm re-signed; they still
contain that Debug-only setting. For public Device Farm runs use HTTPS.

## 7. Analyze received JSONLs on Linux

```bash
python3 bench/analyze.py bench/results/received --output bench/results/summary
```

The directory must contain SDK run JSONLs only, not origin logs. CSV/Markdown
report per (strategy, format, network, script, configuration fingerprint)
p50/p90/p99 TTFF, fraction of **all activations** at or below 100ms, separate first-video and swipe p50/p90/p99 and fractions at or below 100/150ms, censored activations, first-10s stalls,
network/cache/wasted bytes, errors, max live players and sampled memory.
Quantiles include displayed frames only; censored views are always shown.
Analysis rejects malformed/truncated JSONL, missing/duplicate runEnd, unmatched
frames/views, missing startup summaries and inconsistent monotonic timing.
`--allow-incomplete` is diagnostic only, never smoke proof/headline results.

Headers record the full serialized configuration and SHA256 fingerprint, run/
format/network/script labels, device/OS/build SHA, simulator flag and grid cell/
cache-state dimensions. Startup summaries cover up to ten wall-clock seconds
from the request, or until leaving; a binge view does not claim ten seconds of
observation. Network bytes are received media payload, excluding protocol/TLS
headers, manifest-fetch/poster/result traffic and OS network totals. Cache bytes
include probes/repeated reads. Wasted prefetch means bytes never supplied to
activated playback, not pixels never watched. See ARCHITECTURE for detector
refresh-period uncertainty and immutable-VOD limits.

Simulator tables must be labeled **“simulator smoke run — not benchmark
numbers”**. Physical iPhone/Device Farm validation remains necessary for display
latency, layer swaps, RAM/decoder/thermal behavior, actual network profiles,
HTTPS/HTTP2, signing/re-signing/installation and unattended result delivery.

Review validation can build the Release simulator configuration with
`xcodebuild build-for-testing -configuration Release -sdk iphonesimulator ...`.
Its generated Info.plist has **no NSAppTransportSecurity keys**. The SDK probes
its numeric loopback endpoint and automatically uses direct media URLs if the
host policy blocks it; partners need no ATS exception for the SDK.
Set `HM_BACKGROUND_SECONDS=3` on `bench/run.py` to have the thin XCTest wrapper
background the app during playback, reactivate it, and await the same grid.
The in-app autopilot waits for foreground before committing its next page.

Cache identity includes every query parameter by default. SDK hosts can configure
`volatileSigningQueryParameters` with an explicit list of signing names to ignore;
this never removes unrelated query variants. Playlists use a three-second memory
TTL only; they are not retained across relaunch. Benchmark cache resets use the
shared cache actor between runs instead of deleting files behind live controllers.


## Adaptive performance grid and stdlib throttle

Adaptive mode defaults to on. Set a cell's `knobs.adaptive` to 0 for the fixed
control. [Adaptive prefetch](ADAPTIVE_PREFETCH.md) lists every policy threshold
knob, the public provider interface and measurement/analysis semantics. All
existing grid knobs remain supported.

An optional origin throttle provides shared capacity across simultaneous requests:

```bash
python3 bench/origin.py --root bench/generated/adaptive --port 18413 \
  --bandwidth-bytes-per-second 4000000 --latency-ms 10 \
  --log bench/results/origin-fast.jsonl
python3 bench/origin.py --root bench/generated/adaptive --port 18414 \
  --bandwidth-bytes-per-second 300000 --latency-ms 150 \
  --log bench/results/origin-slow.jsonl
```

Both options default to zero (unlimited bandwidth / no added latency). Range and
HEAD semantics are retained. Rates are bytes/sec; latency is per response, before
headers. Logs record both knobs. The rate is shared across requests, so adding
prefetch workers does not multiply the configured capacity.

`python3 bench/prepare_adaptive_smoke.py --source Sample/LocalMedia/your-clip.mp4` prepares eight distinct media paths,
a two-rendition HLS ladder, MP4 faststart fixtures, and a 16-cell `grid.json`.
It uses the existing ffmpeg; no installation is performed. Start a receiver on
18415 and the two origins above. Build/install on a dedicated simulator,
then launch the app with `--hm-grid-url http://127.0.0.1:18413/grid.json`.
The app drives settled page transitions and posts complete JSONLs. The smoke has
two moves per cell, one-second binge dwell and five-second normal dwell, with
`require_frame=true`. Pass `--normal-dwell 9 --swipes 3` to exercise the default
long-dwell rule. This is functional smoke, not a physical-device benchmark.

## Ready-layer display continuity

The surface observes display boundaries while a warm incoming page is visible
during the swipe animation. If the same item's layer remains attached, opaque,
ready and visible across the preceding and current boundaries, it can report
that frame on the first boundary after page commit. Previously the detector
started observing only after activation propagated through SwiftUI, then waited
for two more boundaries. Offscreen, detached, recycled, hidden and unready layers
clear continuity. Inactive observation is limited to the immediate ±1 pages;
other attached cells do not run display links. The hosted layer must exactly
match the surface bounds. Resume seeks hide the old frame, invalidate continuity
at both seek start and completion, and require fresh display boundaries after
completion. No pre-seek frame or preroll timestamp is reported as TTFF: the request clock is
the final-target lift clock for known touch destinations, or the settled callback for programmatic/unknown targets; firstFrame uses the current post-commit
display boundary. HMPlayerNode still validates activation identity, native item
status and layer readiness. Cold frames retain the two-boundary requirement.

The analyzer retains aggregate TTFF fields in CSV for compatibility. Its printed
table uses separate first-video and swipe fields, with runs, censor counts,
stalls, bytes and sampled memory. Each threshold percentage divides by all
activations of that kind, including views that never displayed a frame. The
first-video population is one play activation per grid repeat; three repeats
therefore provide only three first-video observations per cell.

## Horizontal / mixed-orientation smoke

Landscape source clips follow the same short-side ladder as portrait sources. A 1280×720 (or larger 16:9) source produces 1280×720 `mp4-faststart-720.mp4` plus 2-second HLS at 720/540/360, with the same GOP, bitrate, faststart verification and no-upscale rules. Keep both portrait and landscape MP4 sources in your source directory. `encode.sh` publishes `aspectRatio` hints in all playback manifests, `mixed-orientation.json` alternating portrait/landscape and MP4/HLS, and `inline-landscape.json` for the non-paging scenario. With only one orientation, only applicable manifests are generated.

```bash
bench/encode.sh YOUR_SOURCES bench/generated/horizontal http://127.0.0.1:18490 2
cp bench/grid.horizontal.json bench/generated/horizontal/
python3 bench/origin.py --root bench/generated/horizontal --port 18490
# In a second terminal:
python3 bench/results_receiver.py --port 18491 --output bench/results/horizontal/received
# Build/install the Sample on a dedicated simulator, then:
xcrun simctl launch SIM_UDID com.hotmic.HotMicPlayerDemo \
  --hm-grid-url http://127.0.0.1:18490/grid.horizontal.json
python3 bench/analyze.py bench/results/horizontal/received --output bench/results/horizontal/summary
```

The committed grid runs S0 versus S3, binge (1 s) and normal (5 s) mixed-feed cells with 12 settled swipes, plus S0/S3 inline cells with six next-item transitions. Increase repeats/swipes for device measurements. `scenario: "inline"` renders `HMPlayerView` at its default 16:9 and calls `next()` / `previous()` instead of paging; the JSONL dimension `paging` distinguishes `inline-next` from `in-app-settled-page`. Inline transitions appear in first/navigation TTFF columns, not swipe columns. Each cell can set `presentation` to an `HMVideoPresentation` raw value; the horizontal grid explicitly uses `"fitWithBlurredBackdrop"`. Omitting it uses the preset's presentation. Cache reset / displayed-frame requirements match feed smoke.

Analysis includes `orientation` (`portrait`, `landscape`, `square`, `unknown`, and aggregate `all`), determined from decoded first-frame/summary metadata so cold arrivals without hints are classified after decode. Orientation is the media's display orientation, independent of the device orientation. Censored activations retain their hint or stay unknown. Per-orientation startup/stall and item-attributable transfer counters accompany TTFF. Use `all` rows for run-level totals (including wasted prefetch bytes); do not sum `all` and orientation rows together. Old JSONL without aspect metadata is reported as unknown.

For visual/continuity proof launch the horizontal lab (Sample README), capture each policy and inline/fullscreen with `simctl io SIM_UDID screenshot`, and save under gitignored `bench/results/horizontal/`. Compare the state's native assignment and activation ID and the JSONL first-frame count before/after fullscreen; the playhead must continue, with no new first-frame or stall event. Check API entry/exit, physical simulator rotation, and disabled feed swipe while fullscreen. Run only against an owned dedicated simulator. Simulator output must remain labeled **simulator smoke run — not benchmark numbers**; it cannot establish physical-device latency targets.

## Local pre-roll smoke

After preparing the adaptive local fixture with fast origin port 18423 and results receiver port 18425, copy `bench/grid.ads.json` into that fixture directory and serve it. Launch the Sample with `--hm-grid-url http://127.0.0.1:18423/grid.ads.json`. The grid runs S3 MP4/HLS binge controls, the same feed cells after a generated three-second landscape local pre-roll, and a standalone ad cell. Each cell requires displayed content frames and six transitions; no ad-network calls or media downloads are needed for the pre-roll itself.

The `ads` and `ads-inline` scenarios consult a fake provider on every visit but attach a pre-roll only to the initial item. Subsequent swipes measure the protected next content head. JSONL records `adStateChanged`, `adBreakEnded` and `adPrefetchChanged`, alongside normal content measurements. Content's first TTFF excludes intentional ad duration; no-fill visits retain the original navigation clock. Compare the first swipe after the ad and later swipe distributions against the controls. Simulator results are smoke evidence, not physical-device benchmark numbers or proof of device latency targets.
