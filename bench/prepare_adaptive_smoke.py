#!/usr/bin/env python3
"""Prepare reproducible local adaptive-vs-fixed simulator smoke (not a benchmark).
Requires an existing ffmpeg. Origin and receiver are separate stdlib processes.
"""
import argparse, json, pathlib, shutil, subprocess


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--root', default='bench/generated/adaptive')
    p.add_argument('--fast-port', type=int, default=18413)
    p.add_argument('--slow-port', type=int, default=18414)
    p.add_argument('--results-port', type=int, default=18415)
    a = p.parse_args()
    root = pathlib.Path(a.root).resolve(); root.mkdir(parents=True, exist_ok=True)
    repo = pathlib.Path(__file__).resolve().parent.parent
    source = repo / 'Sample/HotMicPlayerDemo/Resources/coach-mic.mp4'
    fixture = root / 'fixture'; fixture.mkdir(exist_ok=True)
    common = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', str(source),
              '-t', '12', '-vf', 'scale=360:-2', '-c:v', 'libx264', '-preset', 'ultrafast',
              '-g', '60', '-sc_threshold', '0', '-c:a', 'aac', '-b:a', '64k']
    subprocess.run(common + ['-b:v', '600k', '-movflags', '+faststart', str(fixture / 'clip.mp4')], check=True)
    for name, rate in [('low', '400k'), ('high', '1000k')]:
        folder = fixture / name; folder.mkdir(exist_ok=True)
        subprocess.run(common + ['-b:v', rate, '-f', 'hls', '-hls_time', '2', '-hls_playlist_type', 'vod',
                                '-hls_segment_filename', str(folder / 'segment-%03d.ts'), str(folder / 'index.m3u8')], check=True)
    (fixture / 'master.m3u8').write_text('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=500000\nlow/index.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=1200000\nhigh/index.m3u8\n')
    for index in range(8):
        shutil.copytree(fixture, root / f'item-{index}', dirs_exist_ok=True)
    cells = []
    for speed, port in [('fast', a.fast_port), ('slow', a.slow_port)]:
        for fmt, media in [('mp4', 'clip.mp4'), ('hls', 'master.m3u8')]:
            name = f'{speed}-{fmt}.json'
            (root / name).write_text(json.dumps([dict(id=f'{fmt}-{i}', url=f'http://127.0.0.1:{port}/item-{i}/{media}',
                format=fmt, duration=12) for i in range(8)], indent=2) + '\n')
            for script in ['binge', 'normal']:
                for adaptive in [1, 0]:
                    cells.append(dict(id=f'{speed}-{fmt}-{script}-a{adaptive}', strategy='S3', format=f'{speed}-{fmt}',
                        playlist_url=name, script=script, repeats=1, swipes=3, dwell_seconds=1 if script == 'binge' else 9,
                        reset_cache=True, require_frame=True, knobs={'adaptive': adaptive}))
    (root / 'grid.json').write_text(json.dumps(dict(run_prefix='adaptive-smoke', network='origin-throttle',
        results_url=f'http://127.0.0.1:{a.results_port}/runs', cells=cells), indent=2) + '\n')
    print(f'Prepared {root}/grid.json; fast 4000000 B/s + 10ms; slow 300000 B/s + 150ms.')


if __name__ == '__main__': main()
