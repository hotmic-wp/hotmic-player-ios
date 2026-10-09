#!/usr/bin/env python3
"""Build a short HLS VOD fixture from bundled content using an existing ffmpeg."""
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
output = root / "bench/generated/lab-hls"
output.mkdir(parents=True, exist_ok=True)
subprocess.run([
    "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i",
    str(root / "Sample/HotMicPlayerDemo/Resources/coach-mic.mp4"),
    "-t", "12", "-vf", "scale=360:-2", "-c:v", "libx264", "-preset", "ultrafast",
    "-g", "60", "-sc_threshold", "0", "-c:a", "aac", "-f", "hls", "-hls_time", "2",
    "-hls_playlist_type", "vod", "-hls_segment_filename", str(output / "segment-%03d.ts"),
    str(output / "index.m3u8")
], check=True)
print(f"Created {output}; run python3 bench/origin.py --root bench/generated --port 8088")
