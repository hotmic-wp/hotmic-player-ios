#!/usr/bin/env bash
set -euo pipefail
# Usage: encode.sh [source-directory] [output-directory] [origin-base-url] [keyframe-seconds]
# Supply your own clips with permission for your intended use. None are bundled.
source_dir=${1:-Sample/LocalMedia}
out=${2:-bench/generated}
base=${3:-http://127.0.0.1:8088}
key=${4:-2}
case "$key" in 1|2) ;; *) echo 'keyframe interval must be 1 or 2 seconds' >&2; exit 2;; esac
for tool in ffmpeg ffprobe python3; do command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }; done
mkdir -p "$out"
gop=$((key * 30))
for src in "$source_dir"/*.mp4; do
  [ -f "$src" ] || continue
  id=$(basename "$src" .mp4)
  mkdir -p "$out/$id"
  for size in 1080 720 360; do
    height=$((size * 16 / 9))
    bitrate=4500k; [ "$size" != 720 ] || bitrate=1600k; [ "$size" != 360 ] || bitrate=500k
    extra=(); [ -z "${ENCODE_SECONDS:-}" ] || extra=(-t "$ENCODE_SECONDS")
    ffmpeg -hide_banner -loglevel error -y -i "$src" "${extra[@]}" -map 0:v:0 -map '0:a:0?' \
      -vf "scale=$size:$height:force_original_aspect_ratio=decrease,pad=$size:$height:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30" \
      -c:v libx264 -preset "${ENCODE_PRESET:-veryfast}" -threads "${ENCODE_THREADS:-2}" -pix_fmt yuv420p -profile:v high \
      -b:v "$bitrate" -maxrate "$bitrate" -bufsize "$bitrate" -g "$gop" -keyint_min "$gop" -sc_threshold 0 \
      -c:a aac -b:a 96k -ar 48000 -movflags +faststart "$out/$id/mp4-faststart-$size.mp4"
  done
  ffmpeg -hide_banner -loglevel error -y -i "$out/$id/mp4-faststart-1080.mp4" -map 0 -c copy "$out/$id/mp4-no-faststart-1080.mp4"
  for segment in 2 6; do
    mkdir -p "$out/$id/hls-${segment}s"
    for size in 360 720 1080; do
      mkdir -p "$out/$id/hls-${segment}s/$size"
      ffmpeg -hide_banner -loglevel error -y -i "$out/$id/mp4-faststart-$size.mp4" -map 0 -c copy \
        -f hls -hls_time "$segment" -hls_playlist_type vod -hls_segment_type fmp4 \
        -hls_fmp4_init_filename init.mp4 -hls_flags independent_segments \
        -hls_segment_filename "$out/$id/hls-${segment}s/$size/segment-%03d.m4s" "$out/$id/hls-${segment}s/$size/index.m3u8"
    done
    cat > "$out/$id/hls-${segment}s/master.m3u8" <<'PLAYLIST'
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-STREAM-INF:BANDWIDTH=650000,RESOLUTION=360x640,CODECS="avc1.64001f,mp4a.40.2"
360/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1800000,RESOLUTION=720x1280,CODECS="avc1.64001f,mp4a.40.2"
720/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=4800000,RESOLUTION=1080x1920,CODECS="avc1.640028,mp4a.40.2"
1080/index.m3u8
PLAYLIST
  done
  ffmpeg -hide_banner -loglevel error -y -ss 1 -i "$out/$id/mp4-faststart-720.mp4" -frames:v 1 -vf scale=360:-2 "$out/$id/poster.jpg"
done
python3 - "$out" "$base" "$key" <<'PY'
import hashlib,json,pathlib,subprocess,sys
out=pathlib.Path(sys.argv[1]); base=sys.argv[2].rstrip('/')
ids=sorted(p.name for p in out.iterdir() if p.is_dir() and (p/'mp4-faststart-720.mp4').exists())
if not ids: raise SystemExit('No source MP4s found')
variants={'mp4-faststart-1080':'mp4-faststart-1080.mp4','mp4-faststart-720':'mp4-faststart-720.mp4','mp4-no-faststart-1080':'mp4-no-faststart-1080.mp4','hls-2s':'hls-2s/master.m3u8','hls-6s':'hls-6s/master.m3u8'}
durations={i:float(subprocess.check_output(['ffprobe','-v','error','-show_entries','format=duration','-of','csv=p=0',str(out/i/'mp4-faststart-720.mp4')])) for i in ids}
for variant,path in variants.items():
    items=[dict(id=f'{n+1:03d}-{i}',url=f'{base}/{i}/{path}',poster=f'{base}/{i}/poster.jpg',format=variant,duration=durations[i]) for n in range(80) for i in [ids[n%len(ids)]]]
    (out/f'{variant}.json').write_text(json.dumps(items,indent=2)+'\n')
(out/'encoding.json').write_text(json.dumps(dict(keyframe_seconds=int(sys.argv[3]),fps=30,sources=ids,variants=variants),indent=2)+'\n')
with (out/'checksums.sha256').open('w') as f:
    for p in sorted(out.rglob('*')):
        if p.is_file() and p.name!='checksums.sha256':
            f.write(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+str(p.relative_to(out))+'\n')
print(f'Encoded {len(ids)} source clips; manifests and checksums: {out}')
PY
