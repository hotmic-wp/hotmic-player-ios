#!/bin/bash
# Generate SDK-owned synthetic media. No source footage, audio, or network input.
set -euo pipefail
cd "$(dirname "$0")"
for duration in 1 3 20; do
  ffmpeg -nostdin -hide_banner -loglevel error -f lavfi \
    -i "color=c=gray:s=160x90:r=10:d=$duration" -an -c:v libx264 \
    -pix_fmt yuv420p -preset veryslow -crf 28 -threads 1 \
    -fflags +bitexact -flags:v +bitexact -map_metadata -1 \
    -movflags +faststart -n "landscape-$duration.mp4"
done
ffmpeg -nostdin -hide_banner -loglevel error -display_rotation 90 -i landscape-1.mp4 \
  -c copy -map_metadata -1 -movflags +faststart \
  -n portrait-1.mp4
shasum -a 256 ./*.mp4
