#!/usr/bin/env bash
set -euo pipefail
# Usage: encode.sh [source-directory] [output-directory] [origin-base-url] [keyframe-seconds]
# Env: CLIP_LIST (clip-list.json: verify source sha256 + category/length in manifest.json),
#      CONTENT_MANIFEST (also write manifest.json there), ENCODE_JOBS (clips in parallel, default 1),
#      ENCODE_PRESET (default veryfast), ENCODE_THREADS (per ffmpeg, default 2), ENCODE_SECONDS (smoke only),
#      HLS_AS_SERVED (lines "<id> <master-url>": mirror each clip's served HLS byte for byte as hls-as-served).
source_dir=${1:-Sample/HotMicPlayerDemo/Resources}
out=${2:-bench/generated}
base=${3:-http://127.0.0.1:8088}
key=${4:-2}
case "$key" in 1|2) ;; *) echo 'keyframe interval must be 1 or 2 seconds' >&2; exit 2;; esac
for tool in ffmpeg ffprobe; do command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }; done
# python3 on macOS/Linux; on Windows python3 is often a do-nothing Store stub, so probe it.
if python3 -c '' 2>/dev/null; then py=python3; elif python -c '' 2>/dev/null; then py=python; else echo 'Missing python3' >&2; exit 1; fi
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out/.timings"
# Recorded in encoding.json, so a later manifest-only rebuild keeps the settings the media was encoded with.
printf '{"preset":"%s","smoke_seconds":"%s"}\n' "${ENCODE_PRESET:-veryfast}" "${ENCODE_SECONDS:-}" > "$out/.timings/settings.json"
[ -z "${CLIP_LIST:-}" ] || "$py" "$here/encode_manifest.py" verify "$source_dir" "$CLIP_LIST"
# Every clip is normalised to 30 fps so the GOP (key*30 frames) is identical for every clip and variant.
export out gop=$((key * 30))
# Rungs are named by the short side and capped at the source's short side: never upscale, never pad.
# 1080/720 are the MP4 sizes; 720/540/360 are the HLS ladder. Each HLS rung remuxes the MP4 of that rung.
encode_clip() {
  local src=$1 id dir w h short portrait rung rungs=() top='' began=$SECONDS
  id=$(basename "$src" .mp4); dir="$out/$id"; mkdir -p "$dir"
  IFS=x read -r w h < <(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$src" | tr -d '\r')
  short=$((w < h ? w : h)); portrait=$((h >= w))
  for rung in 1080 720 540 360; do [ "$rung" -gt "$short" ] || rungs+=("$rung"); done
  [ ${#rungs[@]} -gt 0 ] || { echo "$id: ${w}x$h is below the 360 rung; skipped" >&2; return 0; }
  local extra=(); [ -z "${ENCODE_SECONDS:-}" ] || extra=(-t "$ENCODE_SECONDS")
  for rung in "${rungs[@]}"; do
    local scale bitrate
    scale="scale=-2:$rung"; [ "$portrait" = 0 ] || scale="scale=$rung:-2"
    case "$rung" in 1080) bitrate=4500;; 720) bitrate=2400;; 540) bitrate=1200;; 360) bitrate=600;; esac
    local video=(-map 0:v:0 -vf "$scale,setsar=1,fps=30" -c:v libx264 -preset "${ENCODE_PRESET:-veryfast}"
      -threads "${ENCODE_THREADS:-2}" -pix_fmt yuv420p -profile:v high
      -b:v "${bitrate}k" -maxrate "$((bitrate * 3 / 2))k" -bufsize "$((bitrate * 2))k"
      -g "$gop" -keyint_min "$gop" -sc_threshold 0 -passlogfile "$dir/.pass-$rung")
    ffmpeg -hide_banner -loglevel error -y -i "$src" "${extra[@]}" "${video[@]}" -pass 1 -an -f null -
    ffmpeg -hide_banner -loglevel error -y -i "$src" "${extra[@]}" "${video[@]}" -pass 2 -map '0:a:0?' \
      -c:a aac -b:a 96k -ar 48000 -movflags +faststart "$dir/mp4-faststart-$rung.mp4"
    rm -f "$dir/.pass-$rung"*
  done
  # The no-faststart control remuxes the same samples with moov after mdat, like the hls-to-mp4 Lambda.
  # MP4 sizes are 1080 and 720; a clip whose source is below 720 gets one MP4 at its top rung.
  for rung in "${rungs[@]}"; do
    if [ "$rung" -ge 720 ] || [ -z "$top" ]; then
      ffmpeg -hide_banner -loglevel error -y -i "$dir/mp4-faststart-$rung.mp4" -map 0 -c copy "$dir/mp4-no-faststart-$rung.mp4"
    fi
    top=${top:-$rung}
  done
  for segment in 2 6; do
    for rung in "${rungs[@]}"; do
      [ "$rung" -le 720 ] || continue
      mkdir -p "$dir/hls-${segment}s/$rung"
      ffmpeg -hide_banner -loglevel error -y -i "$dir/mp4-faststart-$rung.mp4" -map 0 -c copy \
        -f hls -hls_time "$segment" -hls_playlist_type vod -hls_segment_type fmp4 \
        -hls_fmp4_init_filename init.mp4 -hls_flags independent_segments \
        -hls_segment_filename "$dir/hls-${segment}s/$rung/segment-%03d.m4s" "$dir/hls-${segment}s/$rung/index.m3u8"
    done
  done
  ffmpeg -hide_banner -loglevel error -y -ss 1 -i "$dir/mp4-faststart-$top.mp4" -frames:v 1 -vf scale=360:-2 "$dir/poster.jpg"
  echo "$((SECONDS - began))" > "$out/.timings/$id"
  echo "$id: ${w}x$h -> rungs ${rungs[*]} in $((SECONDS - began))s"
}
export -f encode_clip
find "$source_dir" -maxdepth 1 -name '*.mp4' -print0 | sort -z |
  xargs -0 -r -n 1 -P "${ENCODE_JOBS:-1}" bash -c 'encode_clip "$1"' _
[ -z "${HLS_AS_SERVED:-}" ] || "$py" "$here/mirror_hls.py" "$out" "$HLS_AS_SERVED"
"$py" "$here/encode_manifest.py" build "$out" "$base" "$key" ${CLIP_LIST:+--clip-list "$CLIP_LIST"} \
  ${CONTENT_MANIFEST:+--copy "$CONTENT_MANIFEST"}
