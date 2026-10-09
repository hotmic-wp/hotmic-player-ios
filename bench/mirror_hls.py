#!/usr/bin/env python3
"""Mirror HLS presentations byte for byte into <out>/<id>/hls-as-served/.

Usage: mirror_hls.py <out> <list-file>   (list-file lines: "<id> <master-url>")

Every URI the master references (variant and rendition playlists, EXT-X-MAP inits,
segments) is fetched and saved under its own relative path, unchanged, so the copy
plays from any origin. Absolute or parent-relative URIs are refused rather than
rewritten. encode_manifest.py build records the result as the hls-as-served variant.
"""
import concurrent.futures, pathlib, re, sys, urllib.parse, urllib.request

URI_ATTR = re.compile(r'URI="([^"]+)"')


def fetch(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'hotmic-bench-mirror'}), timeout=60) as r:
        body = r.read()
        length = r.headers.get('Content-Length')
        if length is not None and int(length) != len(body):
            raise IOError(f'{url}: got {len(body)} of {length} bytes')
        return body


def references(text):
    """URIs a playlist references: tag URI attributes and plain URI lines."""
    refs = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith('#'):
            refs += URI_ATTR.findall(line)
        else:
            refs.append(line)
    return refs


def safe_relative(uri):
    parts = urllib.parse.urlsplit(uri)
    if parts.scheme or parts.netloc or uri.startswith('/') or '..' in pathlib.PurePosixPath(parts.path).parts:
        raise ValueError(f'{uri}: not a plain relative URI; mirroring it byte for byte would break playback')
    return parts.path


def mirror(out, cid, master_url):
    dest = pathlib.Path(out) / cid / 'hls-as-served'
    base = master_url.rsplit('/', 1)[0] + '/'
    master_name = safe_relative(master_url.rsplit('/', 1)[1])
    playlists, media, seen = [master_name], [], set()
    while playlists:  # playlists first (they name everything else), then media in parallel
        name = playlists.pop()
        if name in seen:
            continue
        seen.add(name)
        body = fetch(base + name)
        (dest / name).parent.mkdir(parents=True, exist_ok=True)
        (dest / name).write_bytes(body)
        prefix = name.rsplit('/', 1)[0] + '/' if '/' in name else ''
        for ref in references(body.decode('utf-8')):
            rel = prefix + safe_relative(ref)
            (playlists if rel.endswith('.m3u8') else media).append(rel)
    media = sorted(set(media) - seen)

    def get(rel):
        (dest / rel).parent.mkdir(parents=True, exist_ok=True)
        (dest / rel).write_bytes(fetch(base + rel))
        return (dest / rel).stat().st_size

    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        total = sum(pool.map(get, media))
    print(f'{cid}: {len(seen)} playlists + {len(media)} files, {total} media bytes')


def main():
    out, list_file = sys.argv[1:3]
    for line in pathlib.Path(list_file).read_text().splitlines():
        if line.strip() and not line.startswith('#'):
            cid, url = line.split()
            mirror(out, cid, url)


if __name__ == '__main__':
    main()
