#!/usr/bin/env python3
"""Generate tiny synthetic UI-regression MP4/HLS fixtures, then serve loopback only.

Requires ffmpeg. No input media, private checkout, grid, network shaping or result export.
Run from the repository root; generated media stays in ignored .bench/public-fixtures.
"""
import argparse
import functools
import http.server
import json
import pathlib
import re
import subprocess
import shutil

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=pathlib.Path, default=pathlib.Path('.bench/public-fixtures'))
parser.add_argument('--port', type=int, default=18490)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
entries = []
for index, (shape, kind) in enumerate([('portrait', 'mp4'), ('landscape', 'mp4'), ('portrait', 'hls'), ('landscape', 'hls')], 1):
    name = f'{index:03d}-{shape}'
    directory = args.output / name
    directory.mkdir(exist_ok=True)
    size = '180x320' if shape == 'portrait' else '320x180'
    media = directory / ('clip.mp4' if kind == 'mp4' else 'index.m3u8')
    command = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', f'testsrc2=size={size}:rate=15',
               '-t', '12', '-an', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-g', '30']
    command += ['-movflags', '+faststart'] if kind == 'mp4' else ['-f', 'hls', '-hls_time', '2', '-hls_playlist_type', 'vod']
    subprocess.run(command + [str(media)], check=True)
    entries.append(dict(id=name, url=f'{name}/{media.name}', format=kind, duration=12, aspectRatio=9 / 16 if shape == 'portrait' else 16 / 9))
(args.output / 'manifest.json').write_text(json.dumps(entries, indent=2) + '\n')
fixture = args.output / 'fixture'
fixture.mkdir(exist_ok=True)
shutil.copyfile(args.output / '001-portrait/clip.mp4', fixture / 'clip.mp4')
for segment in (args.output / '003-portrait').iterdir():
    shutil.copyfile(segment, fixture / ('master.m3u8' if segment.name == 'index.m3u8' else segment.name))
for language, text in [('en', 'Generated caption fixture'), ('es', 'Subtitulo de prueba')]:
    (fixture / f'{language}.vtt').write_text(f'WEBVTT\n\n00:00.000 --> 00:10.000\n{text}\n')


class Fixtures(http.server.SimpleHTTPRequestHandler):
    """Only single byte ranges, sufficient for the public native-player regressions."""
    def send_head(self):
        path = pathlib.Path(self.translate_path(self.path))
        match = re.fullmatch(r'bytes=(\d+)-(\d*)', self.headers.get('Range', ''))
        self.remaining = None
        if not match or not path.is_file():
            return super().send_head()
        total = path.stat().st_size
        start = int(match[1]); end = min(int(match[2]) if match[2] else total - 1, total - 1)
        if start > end:
            self.send_response(416); self.send_header('Content-Range', f'bytes */{total}'); self.end_headers(); return None
        self.send_response(206)
        self.send_header('Content-Type', self.guess_type(str(path)))
        self.send_header('Content-Range', f'bytes {start}-{end}/{total}')
        self.send_header('Content-Length', str(end - start + 1))
        self.end_headers()
        source = path.open('rb'); source.seek(start); self.remaining = end - start + 1
        return source
    def copyfile(self, source, output):
        if self.remaining is None:
            return super().copyfile(source, output)
        try:
            while self.remaining:
                data = source.read(min(65536, self.remaining))
                if not data: break
                output.write(data); self.remaining -= len(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

print(f'Public regression manifest: http://127.0.0.1:{args.port}/manifest.json', flush=True)
handler = functools.partial(Fixtures, directory=str(args.output.resolve()))
http.server.ThreadingHTTPServer(('127.0.0.1', args.port), handler).serve_forever()
