# HotMicPlayer Sample

Open `HotMicPlayerDemo.xcodeproj`, select **HotMicPlayerDemo**, and run on an iPhone simulator. The partner demo, horizontal/inline view and playlist editing screens use ordinary public SDK imports. The default feed streams public test media; no video or poster is bundled in Git. [PlayerOnly](../Examples/PlayerOnly) and [PlayerWithUI](../Examples/PlayerWithUI) are smaller integration starting points.

The separate **HotMicPlayerRegression** scheme retains public SDK behavior tests. Its opt-in DEBUG diagnostics live in [TestSupportTools](TestSupportTools/README.md), distinct from partner flows; no benchmark grid, upload or Device Farm runner is included.

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

Use **Horizontal** for the same-player feed/inline/fullscreen example and **Playlist** for append, insert, remove, reconcile, navigation and seeking. Both use the demo source above without an origin service. **Partner demo** and **Social layout** show public engagement, overlay and gesture integrations with host-owned fake services and synthetic media.

Debug builds allow local networking for opt-in regression fixtures. Release builds omit that exception. Use HTTPS for public sources; the SDK does not require a host ATS exception.

To compile without signing, from the repository root:

```bash
xcodebuild build -project Sample/HotMicPlayerDemo.xcodeproj -scheme HotMicPlayerDemo \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

Physical installation requires the host's normal development signing. See [horizontal video](../Sources/HotMicPlayer/HotMicPlayer.docc/HorizontalVideo.md), [playlist management](../Sources/HotMicPlayer/HotMicPlayer.docc/PlaylistManagement.md), [ads](../Sources/HotMicPlayer/HotMicPlayer.docc/Ads.md) and [captions/audio/accessibility](../Sources/HotMicPlayer/HotMicPlayer.docc/Captions.md) for integration contracts.
