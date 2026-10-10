#!/usr/bin/env python3
"""Generate owned synthetic MP4/HLS + WebVTT, and paired S3 caption smoke cells."""
import argparse
import json
import pathlib
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', default='bench/generated/captions')
    parser.add_argument('--port', type=int, default=18433)
    parser.add_argument('--results-port', type=int, default=18435)
    args = parser.parse_args()
    root = pathlib.Path(args.root).resolve()
    fixture = root / 'fixture'
    fixture.mkdir(parents=True, exist_ok=True)
    command = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
               '-f', 'lavfi', '-i', 'testsrc2=size=360x640:rate=30',
               '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
               '-t', '12', '-c:v', 'libx264', '-preset', 'ultrafast', '-b:v', '600k',
               '-g', '60', '-sc_threshold', '0', '-c:a', 'aac', '-b:a', '64k']
    subprocess.run(command + ['-movflags', '+faststart', str(fixture / 'clip.mp4')], check=True)
    subprocess.run(command + ['-f', 'hls', '-hls_time', '2', '-hls_playlist_type', 'vod',
                             '-hls_segment_filename', str(fixture / 'segment-%03d.ts'), str(fixture / 'video.m3u8')], check=True)
    caption = pathlib.Path(__file__).parent.parent / 'Sample/HotMicPlayerDemo/Resources/bench.en.vtt'
    probe = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
        '-show_entries', 'stream=start_pts', '-of', 'json', str(fixture / 'segment-000.ts')]))
    start_pts = probe['streams'][0]['start_pts']
    vtt = caption.read_text().replace('WEBVTT\n', f'WEBVTT\nX-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:{start_pts}\n', 1)
    (fixture / 'en.vtt').write_text(vtt)
    (fixture / 'es.vtt').write_text(vtt.replace('HotMic caption', 'Subtítulo HotMic'))
    (fixture / 'subtitles.m3u8').write_text('#EXTM3U\n#EXT-X-TARGETDURATION:12\n#EXT-X-VERSION:3\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:12,\nen.vtt\n#EXT-X-ENDLIST\n')
    (fixture / 'master.m3u8').write_text('#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,FORCED=NO,URI="subtitles.m3u8"\n#EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=360x640,SUBTITLES="subs"\nvideo.m3u8\n')
    cells = []
    for fmt, media in [('mp4', 'clip.mp4'), ('hls', 'master.m3u8')]:
        items = []
        for i in range(8):
            shutil.copytree(fixture, root / f'item-{i}', dirs_exist_ok=True)
            item = dict(id=f'{fmt}-{i}', url=f'item-{i}/{media}', format=fmt, duration=12)
            if fmt == 'mp4':
                item['captions'] = {'en': f'item-{i}/en.vtt'}
            items.append(item)
        (root / f'{fmt}.json').write_text(json.dumps(items, indent=2) + '\n')
        for enabled in [0, 1]:
            cells.append(dict(id=f'S3-{fmt}-cc{enabled}', strategy='S3', format=fmt,
                              playlist_url=f'{fmt}.json', script='binge', repeats=1, swipes=6,
                              reset_cache=True, require_frame=True, knobs={'captions': enabled}))
    (root / 'grid.json').write_text(json.dumps(dict(run_prefix='captions-smoke', network='local-unthrottled',
        results_url=f'http://127.0.0.1:{args.results_port}/runs', cells=cells), indent=2) + '\n')
    print(f'Prepared {root}; serve at http://127.0.0.1:{args.port}')


if __name__ == '__main__':
    main()
