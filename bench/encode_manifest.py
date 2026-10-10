#!/usr/bin/env python3
"""encode.sh helpers.

verify <source-dir> <clip-list.json>: fail unless every listed source exists with its sha256.
build <out> <base-url> <keyframe-seconds> [--clip-list F] [--copy F]: verify GOP and moov
position with ffprobe, write each HLS master playlist from measured bitrates, then the
per-format playlists (<variant>.json), encoding.json, checksums.sha256 and manifest.json.
"""
import argparse, hashlib, json, pathlib, re, subprocess, sys

FPS = 30
LADDER = {1080: 4500, 720: 2400, 540: 1200, 360: 600}  # kbps video; audio is AAC 96k 48 kHz
HLS_RUNGS = (720, 540, 360)
MP4_SIZES = (1080, 720)


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def load_clip_list(path):
    data = json.loads(pathlib.Path(path).read_text(encoding='utf-8'))
    return {row['id']: row for row in data['rows']}


def verify(source_dir, clip_list):
    bad = []
    for cid, row in load_clip_list(clip_list).items():
        p = pathlib.Path(source_dir) / row['file']
        if not p.is_file():
            bad.append(f'{cid}: missing {p}')
        elif sha256(p) != row['sha256']:
            bad.append(f'{cid}: sha256 mismatch')
    if bad:
        raise SystemExit('Source verification failed:\n' + '\n'.join(bad))
    print(f'Verified sha256 of {len(load_clip_list(clip_list))} sources')


def probe(path, entries, stream='v:0'):
    out = subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', stream,
                                   '-show_entries', entries, '-of', 'json', str(path)])
    return json.loads(out)


def video_info(path):
    d = probe(path, 'stream=width,height,avg_frame_rate,profile,level:format=duration')
    s = d['streams'][0]
    num, den = (int(x) for x in s['avg_frame_rate'].split('/'))
    return dict(width=s['width'], height=s['height'], fps=round(num / den, 3) if den else None,
                profile=s['profile'], level=s['level'], duration=round(float(d['format']['duration']), 3))


def keyframes(path):
    d = probe(path, 'packet=pts_time,flags')
    return [float(p['pts_time']) for p in d['packets'] if 'K' in p.get('flags', '') and p.get('pts_time') not in (None, 'N/A')]


def gop_check(times, key):
    """Every keyframe interval equals the keyframe target, within half a frame."""
    gaps = [b - a for a, b in zip(times, times[1:])]
    ok = bool(times) and abs(times[0]) < 0.5 / FPS and all(abs(g - key) < 0.5 / FPS for g in gaps)
    return dict(verified=ok, keyframes=len(times), interval_min=round(min(gaps), 4) if gaps else None,
                interval_max=round(max(gaps), 4) if gaps else None, target=key)


def moov_position(path):
    """Walk top-level MP4 boxes: 'front' if moov precedes mdat, 'end' if after."""
    order = []
    with open(path, 'rb') as f:
        size = f.seek(0, 2)
        pos = 0
        while pos + 8 <= size and len(order) < 2:
            f.seek(pos)
            head = f.read(16)
            n, kind = int.from_bytes(head[:4], 'big'), head[4:8].decode('latin-1')
            if n == 1:
                n = int.from_bytes(head[8:16], 'big')
            elif n == 0:
                n = size - pos
            if kind in ('moov', 'mdat'):
                order.append(kind)
            if n < 8:
                break
            pos += n
    return {('moov', 'mdat'): 'front', ('mdat', 'moov'): 'end'}.get(tuple(order), 'unknown')


def codecs(info):
    profile = {'High': 0x64, 'Main': 0x4d, 'Constrained Baseline': 0x42, 'Baseline': 0x42}[info['profile']]
    return f'avc1.{profile:02x}00{info["level"]:02x},mp4a.40.2'


def hls_rung(rung_dir, mp4_keys, seg_target):
    """Parse a media playlist; check every segment boundary is a keyframe of the remuxed MP4."""
    text = (rung_dir / 'index.m3u8').read_text()
    durations = [float(x) for x in re.findall(r'#EXTINF:([\d.]+)', text)]
    segments = re.findall(r'^(segment-\d+\.m4s)$', text, re.M)
    sizes = [(rung_dir / s).stat().st_size for s in segments]
    bounds, t = [], 0.0
    for d in durations[:-1]:
        t += d
        bounds.append(t)
    aligned = all(any(abs(b - k) < 0.5 / FPS for k in mp4_keys) for b in bounds)
    # Every full segment is a whole number of GOPs; only the last may be shorter.
    whole = all(abs(d - seg_target) < 0.5 / FPS for d in durations[:-1])
    peak = max(s * 8 / d for s, d in zip(sizes, durations) if d > 0)
    files = ['index.m3u8', 'init.mp4'] + segments
    return dict(segments=len(segments), segment_max=round(max(durations), 3), bytes=sum((rung_dir / f).stat().st_size for f in files),
                peak_bps=int(peak), average_bps=int(sum(sizes) * 8 / sum(durations)),
                gop=dict(verified=aligned and whole and bool(mp4_keys), segment_boundaries_on_keyframes=aligned,
                         full_segments_equal_target=whole), files=files)


def write_master(path, rungs):
    lines = ['#EXTM3U', '#EXT-X-VERSION:7', '#EXT-X-INDEPENDENT-SEGMENTS']
    for r in sorted(rungs, key=lambda r: r['rung']):  # lowest first, as before: AVPlayer starts on the first entry
        lines += [f'#EXT-X-STREAM-INF:BANDWIDTH={r["peak_bps"]},AVERAGE-BANDWIDTH={r["average_bps"]},'
                  f'RESOLUTION={r["resolution"]},FRAME-RATE={FPS:.3f},CODECS="{r["codecs"]}"', f'{r["rung"]}/index.m3u8']
    path.write_text('\n'.join(lines) + '\n')


def attrs(line):
    return dict((k, v.strip('"')) for k, v in re.findall(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)', line.split(':', 1)[1]))


def served_variant(out, dest):
    """The ladder as HotMic's CDN serves it (mirror_hls.py): recorded as found, exempt from GOP/cap rules."""
    master = next(dest.glob('master*.m3u8'))
    lines = master.read_text().splitlines()
    rungs, audio = [], None
    for i, line in enumerate(lines):
        if line.startswith('#EXT-X-MEDIA:'):
            audio = attrs(line)
        if line.startswith('#EXT-X-STREAM-INF:'):
            a = attrs(line)
            uri = next(x for x in lines[i + 1:] if x.strip())
            text = (dest / uri).read_text()
            durations = [float(x) for x in re.findall(r'#EXTINF:([\d.]+)', text)]
            times = keyframes(dest / uri)
            gaps = [round(b - a_, 3) for a_, b in zip(times, times[1:])]
            profile_idc = a['CODECS'].split('.')[1][:2]
            w, h = (int(x) for x in a['RESOLUTION'].split('x'))
            rungs.append(dict(listed=len(rungs) + 1, resolution=a['RESOLUTION'], rung=min(w, h), bandwidth=int(a['BANDWIDTH']),
                              codecs=a['CODECS'], profile={'42': 'Baseline', '4d': 'Main', '64': 'High'}.get(profile_idc, profile_idc),
                              path=(dest / uri).relative_to(out).as_posix(), segments=len(durations),
                              segment_max=max(durations), keyframe_interval_min=min(gaps) if gaps else None,
                              keyframe_interval_max=max(gaps) if gaps else None))
    files = sorted(p for p in dest.rglob('*') if p.is_file())
    digest = hashlib.sha256(''.join(f'{sha256(f)}  {f.relative_to(out).as_posix()}\n' for f in files).encode()).hexdigest()
    first = rungs[0]
    info = video_info(out / first['path'])
    return dict(variant='hls-as-served', ticket_variant='hls-as-served', rung=first['rung'], path=master.relative_to(out).as_posix(),
                bytes=sum(f.stat().st_size for f in files), sha256=digest,
                sha256_scope='sha256 of the "<sha256>  <path>" lines of every mirrored file',
                duration=info['duration'], fps=info['fps'], resolution=first['resolution'],
                gop=dict(verified=None, exempt=True, note='mirrored from the CDN byte for byte; recorded as found'),
                moov=dict(position='fragmented', expected='fragmented', verified=True),
                first_listed=first['resolution'], audio=dict(demuxed=audio is not None, uri=audio and audio.get('URI')),
                files=len(files), rungs=rungs)


def build(out, base, key, clip_list, copy):
    out = pathlib.Path(out)
    base = base.rstrip('/')
    meta = load_clip_list(clip_list) if clip_list else {}
    ids = sorted(p.name for p in out.iterdir() if p.is_dir() and not p.name.startswith('.') and any(p.glob('mp4-faststart-*.mp4')))
    if not ids:
        raise SystemExit('No source MP4s found')
    clips, failures = [], []
    for cid in ids:
        d = out / cid
        rungs = sorted((int(p.stem.rsplit('-', 1)[1]) for p in d.glob('mp4-faststart-*.mp4')), reverse=True)
        variants, info_by_rung, keys_by_rung = [], {}, {}
        for rung in rungs:
            info_by_rung[rung] = video_info(d / f'mp4-faststart-{rung}.mp4')
            keys_by_rung[rung] = keyframes(d / f'mp4-faststart-{rung}.mp4')
        for kind, ticket in (('mp4-faststart', 'mp4-fast'), ('mp4-no-faststart', 'mp4-moov-end')):
            for rung in rungs:
                p = d / f'{kind}-{rung}.mp4'
                if not p.exists():
                    continue
                info = info_by_rung[rung]
                gop = gop_check(keyframes(p) if kind == 'mp4-no-faststart' else keys_by_rung[rung], key)
                moov = moov_position(p)
                expected = 'front' if kind == 'mp4-faststart' else 'end'
                variants.append(dict(variant=f'{kind}-{rung}', ticket_variant=ticket, rung=rung,
                                     role='mp4' if rung in MP4_SIZES or rung == rungs[0] else 'hls-source',
                                     path=f'{cid}/{p.name}', bytes=p.stat().st_size, sha256=sha256(p),
                                     duration=info['duration'], fps=info['fps'], resolution=f'{info["width"]}x{info["height"]}',
                                     video_kbps=LADDER[rung], gop=gop, moov=dict(position=moov, expected=expected, verified=moov == expected)))
        for seg in (2, 6):
            hdir = d / f'hls-{seg}s'
            if not hdir.is_dir():
                continue
            hrungs = []
            for rung in [r for r in rungs if r in HLS_RUNGS]:
                info = info_by_rung[rung]
                r = hls_rung(hdir / str(rung), keys_by_rung[rung], seg)
                hrungs.append(dict(rung=rung, resolution=f'{info["width"]}x{info["height"]}', codecs=codecs(info),
                                   path=f'{cid}/hls-{seg}s/{rung}/index.m3u8', **r))
            write_master(hdir / 'master.m3u8', hrungs)
            master = hdir / 'master.m3u8'
            top = hrungs[0]
            all_files = [master] + [hdir / str(r['rung']) / f for r in hrungs for f in r['files']]
            digest = hashlib.sha256(''.join(f'{sha256(f)}  {f.relative_to(out).as_posix()}\n' for f in all_files).encode()).hexdigest()
            for r in hrungs:
                del r['files']
            variants.append(dict(variant=f'hls-{seg}s', ticket_variant=f'hls-{seg}s', rung=top['rung'],
                                 path=f'{cid}/hls-{seg}s/master.m3u8', bytes=sum(f.stat().st_size for f in all_files),
                                 sha256=digest, sha256_scope='sha256 of the "<sha256>  <path>" lines of master + every rung file',
                                 duration=info_by_rung[top['rung']]['duration'], fps=FPS, resolution=top['resolution'],
                                 gop=dict(verified=all(r['gop']['verified'] for r in hrungs), target=key),
                                 moov=dict(position='fragmented', expected='fragmented', verified=True), rungs=hrungs))
        if (d / 'hls-as-served').is_dir():
            variants.append(served_variant(out, d / 'hls-as-served'))
        for v in variants:
            if not v['gop'].get('exempt') and not (v['gop']['verified'] and v['moov']['verified']):
                failures.append(f'{cid} {v["variant"]}: gop={v["gop"]["verified"]} moov={v["moov"]["position"]}')
        m = meta.get(cid, {})
        timing = out / '.timings' / cid  # seconds, written by encode.sh
        clips.append(dict(id=cid, title=m.get('title'), category=m.get('category'), length_bucket=m.get('lengthBucket'),
                          source=dict(file=m.get('file'), sha256=m.get('sha256'), resolution=f'{m["width"]}x{m["height"]}' if m else None,
                                      fps=m.get('fps'), duration=m.get('durationSec')),
                          rungs=rungs, top_rung=rungs[0], mp4_sizes=[r for r in rungs if r in MP4_SIZES] or rungs[:1],
                          hls_rungs=[r for r in rungs if r in HLS_RUNGS], poster=f'{cid}/poster.jpg',
                          encode_seconds=int(timing.read_text()) if timing.exists() else None, variants=variants))

    # Per-format playlists for BenchmarkOptions: 80 items cycling the clips that have that file.
    by_variant = {}
    for c in clips:
        for v in c['variants']:
            by_variant.setdefault(v['variant'], []).append((c, v))
        top = {'mp4-faststart-top': f'mp4-faststart-{c["mp4_sizes"][-1]}', 'mp4-no-faststart-top': f'mp4-no-faststart-{c["mp4_sizes"][-1]}'}
        for alias, real in top.items():  # each clip's MP4 at its HLS top rung (<=720): the like-with-like MP4 set
            by_variant.setdefault(alias, []).extend((c, v) for v in c['variants'] if v['variant'] == real)
    published = {}
    for variant, pairs in sorted(by_variant.items()):
        if variant.startswith('mp4-') and not variant.endswith('-top') and int(variant.rsplit('-', 1)[1]) not in MP4_SIZES:
            continue  # 540/360 MP4s are HLS rung sources; a sub-720 clip's top one is in the -top playlists
        pairs.sort(key=lambda cv: cv[0]['id'])
        items = [dict(id=f'{n + 1:03d}-{c["id"]}', url=f'{base}/{v["path"]}', poster=f'{base}/{c["poster"]}', format=variant,
                      duration=v['duration'], aspectRatio=int(v['resolution'].split('x')[0]) / int(v['resolution'].split('x')[1])) for n in range(80) for c, v in [pairs[n % len(pairs)]]]
        (out / f'{variant}.json').write_text(json.dumps(items, indent=2) + '\n')
        published[variant] = len(pairs)

    # Interleave orientation AND transport for the horizontal feed smoke. Keep distinct URLs/IDs.
    mixed = []
    for orientation in ('portrait', 'landscape'):
        for c in clips:
            for kind in ('mp4-faststart-top', 'hls-2s'):
                for entry, v in by_variant.get(kind, []):
                    if entry['id'] != c['id']: continue
                    w, h = map(int, v['resolution'].split('x'))
                    if (w > h) != (orientation == 'landscape'): continue
                    mixed.append(dict(id=c['id'], url=f'{base}/{v["path"]}', poster=f'{base}/{c["poster"]}',
                                      format=kind, duration=v['duration'], aspectRatio=w/h))
    # Alternate orientations, with MP4 then HLS for each source.
    portraits = [e for e in mixed if e['aspectRatio'] <= 1]
    landscapes = [e for e in mixed if e['aspectRatio'] > 1]
    if portraits and landscapes:
        ordered = [entry for n in range(max(len(portraits), len(landscapes)))
                   for entry in (portraits[n % len(portraits)], landscapes[n % len(landscapes)])]
        (out / 'mixed-orientation.json').write_text(json.dumps([
            dict(e, id=f'{n+1:03d}-{e["id"]}') for n in range(80) for e in [ordered[n % len(ordered)]]], indent=2)+'\n')
    if landscapes:
        (out / 'inline-landscape.json').write_text(json.dumps([
            dict(e, id=f'{n+1:03d}-{e["id"]}') for n in range(80) for e in [landscapes[n % len(landscapes)]]], indent=2)+'\n')

    settings_file = out / '.timings' / 'settings.json'
    settings = json.loads(settings_file.read_text()) if settings_file.exists() else {}
    encoding = dict(keyframe_seconds=key, fps=FPS, gop_frames=key * FPS, x264='2-pass, High, yuv420p, -sc_threshold 0, maxrate 1.5x, bufsize 2x',
                    preset=settings.get('preset'), smoke_seconds=settings.get('smoke_seconds') or None,
                    ladder_kbps=LADDER, hls_rungs=list(HLS_RUNGS), mp4_sizes=list(MP4_SIZES), audio='AAC 96k 48 kHz',
                    cap='rungs named by short side, capped at the source short side; no upscale, no pad, aspect kept',
                    hls_master_order='lowest rung first', sources=ids, playlists=published,
                    variants={c['id']: [v['variant'] for v in c['variants']] for c in clips})
    (out / 'encoding.json').write_text(json.dumps(encoding, indent=2) + '\n')
    manifest = dict(encoding=encoding, base_url=base, clips=clips, failures=failures,
                    total_bytes=sum(v['bytes'] for c in clips for v in c['variants']) + sum((out / c['poster']).stat().st_size for c in clips))
    text = json.dumps(manifest, indent=2, ensure_ascii=False) + '\n'
    (out / 'manifest.json').write_text(text, encoding='utf-8')
    if copy:
        pathlib.Path(copy).parent.mkdir(parents=True, exist_ok=True)
        pathlib.Path(copy).write_text(text, encoding='utf-8')
    with (out / 'checksums.sha256').open('w', newline='\n') as f:
        for p in sorted(out.rglob('*')):
            rel = p.relative_to(out)
            if p.is_file() and p.name != 'checksums.sha256' and not any(part.startswith('.') for part in rel.parts):
                f.write(f'{sha256(p)}  {rel.as_posix()}\n')
    print(f'Encoded {len(ids)} source clips, {manifest["total_bytes"]} bytes; playlists: {published}')
    if failures:
        raise SystemExit('GOP/moov verification failed:\n' + '\n'.join(failures))


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest='cmd', required=True)
    v = sub.add_parser('verify'); v.add_argument('source_dir'); v.add_argument('clip_list')
    b = sub.add_parser('build'); b.add_argument('out'); b.add_argument('base'); b.add_argument('key', type=int)
    b.add_argument('--clip-list'); b.add_argument('--copy')
    a = p.parse_args()
    verify(a.source_dir, a.clip_list) if a.cmd == 'verify' else build(a.out, a.base, a.key, a.clip_list, a.copy)


if __name__ == '__main__':
    sys.exit(main())
