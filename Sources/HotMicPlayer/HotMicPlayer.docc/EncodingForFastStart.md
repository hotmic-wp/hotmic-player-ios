# Encoding and hosting for fast start

Prepare MP4 and HLS VOD so HotMicPlayer can fetch and decode the first frame quickly.

## Overview

Content preparation matters as much as player configuration. Internal device runs on
an iPhone 14 with a roughly 30 Mbps origin showed swipe first frames at approximately
67–117 ms (p50) with content following these rules. These are internal device results,
not a latency guarantee; see the [benchmark guide](https://github.com/hotmic-wp/hotmic-player-sdk/blob/main/docs/BENCHMARKING.md)
for measurement context.

## MP4

Use `+faststart` to put `moov` before `mdat`, so metadata arrives before the media
payload. Encode H.264 High, or HEVC for devices that support it, with a keyframe at
0 s and a 1–2 s GOP. A 720×1280 frame is a good vertical feed default. Use constant
frame rate and AAC audio.

This is the 720×1280 command from [bench/encode.sh](https://github.com/hotmic-wp/hotmic-player-sdk/blob/main/bench/encode.sh)
with its defaults expanded: 30 fps, a 2 s GOP, and optional source audio.

```bash
ffmpeg -hide_banner -loglevel error -y -i input.mp4 -map 0:v:0 -map '0:a:0?' \
  -vf "scale=720:1280:force_original_aspect_ratio=decrease,pad=720:1280:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30" \
  -c:v libx264 -preset veryfast -threads 2 -pix_fmt yuv420p -profile:v high \
  -b:v 1600k -maxrate 1600k -bufsize 1600k -g 60 -keyint_min 60 -sc_threshold 0 \
  -c:a aac -b:a 96k -ar 48000 -movflags +faststart mp4-faststart-720.mp4
```

Serve byte-range requests with `206 Partial Content`, correct `Content-Range` and
`Content-Length`, and `Accept-Ranges: bytes`. Use long-lived cache headers on
immutable, versioned media URLs and HTTP/2 or HTTP/3 on a CDN.

## HLS

Use 1–2 s segments with a keyframe at every segment start and
`#EXT-X-INDEPENDENT-SEGMENTS`. The MP4 command above supplies aligned keyframes
every 2 s. This matching packaging command from `bench/encode.sh` copies those
samples into a VOD fMP4 rendition:

```bash
mkdir -p hls-2s/720
ffmpeg -hide_banner -loglevel error -y -i mp4-faststart-720.mp4 -map 0 -c copy \
  -f hls -hls_time 2 -hls_playlist_type vod -hls_segment_type fmp4 \
  -hls_fmp4_init_filename init.mp4 -hls_flags independent_segments \
  -hls_segment_filename "hls-2s/720/segment-%03d.m4s" "hls-2s/720/index.m3u8"
```

For 1 s segments, use a 30-frame GOP and `-hls_time 1`. When encoding directly to
HLS, align `-force_key_frames 'expr:gte(t,n_forced*2)'` with `-hls_time 2` (use `1`
in both for 1 s). `-hls_time` alone cannot create keyframes with `-c copy`.

Provide a low first rung, such as 360×640 at roughly 600–800 kbps total, so playback
can start low and step up as conditions allow. The benchmark uses 500 kbps video
plus 96 kbps AAC and advertises `BANDWIDTH=650000`. List rungs lowest-first in the
master playlist and supply accurate `BANDWIDTH`/`AVERAGE-BANDWIDTH` values for each
rendition. Explicit prefetch selects one rendition using advertised bandwidth and
the configured startup ceiling; it does not download all rungs in parallel.

fMP4 and TS segments are both fine for ordinary VOD. Cache playlists at the CDN
(a short TTL is fine for VOD) and segments/init files with a long TTL. CDN cache
headers govern edge caching; the SDK separately uses an in-memory playlist TTL and
a bounded disk media cache. CORS is not needed for native playback.

## Hosting checklist

- Keep playlists, init files and segments on the same host when possible to reuse
  one DNS/TLS setup, and enable keep-alive at the CDN/origin.
- Avoid redirects and signed-URL acquisition round trips at start-up. Supply ready
  media URLs; authenticated-origin renewal is outside the supported contract.
- Use immutable, versioned URLs. Live, DRM and advanced HLS byte-range/alternate-audio
  coverage are outside this release's supported contract.
- Optionally supply `HMMediaItem.posterURL` for the first paint while video prepares.

## What the player does for you

With the default configuration, HotMicPlayer prefetches the start of the next few
videos and prepares/prerolls the next one to keep it decoded for a swipe, subject
to buffer health and app limits. A cached byte prefix alone does not guarantee a
decoded frame. See <doc:PrefetchAndPerformance> for budgets and configuration, and
[adaptive prefetch details](https://github.com/hotmic-wp/hotmic-player-sdk/blob/main/docs/ADAPTIVE_PREFETCH.md)
for readiness tiers and safety limits.
