#!/usr/bin/env python3
"""Build short HLS VOD from your own source clip using an existing ffmpeg."""
import argparse
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=pathlib.Path, required=True, help='Your own source clip, with permission for the intended use')
args = parser.parse_args()
output = root / "bench/generated/lab-hls"
output.mkdir(parents=True, exist_ok=True)
subprocess.run([
    "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i",
    str(args.source),
    "-t", "12", "-vf", "scale=360:-2", "-c:v", "libx264", "-preset", "ultrafast",
    "-g", "60", "-sc_threshold", "0", "-c:a", "aac", "-f", "hls", "-hls_time", "2",
    "-hls_playlist_type", "vod", "-hls_segment_filename", str(output / "segment-%03d.ts"),
    str(output / "index.m3u8")
], check=True)
print(f"Created {output}; run python3 bench/origin.py --root bench/generated --port 8088")
