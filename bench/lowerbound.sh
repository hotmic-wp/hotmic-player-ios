#!/usr/bin/env bash
set -euo pipefail
# Usage: lowerbound.sh URL ORIGIN_ACCESS_LOG [result-prefix]
# Use a quiet/dedicated origin: log deltas include concurrent requests otherwise.
if [ "$#" -lt 2 ]; then echo 'Usage: lowerbound.sh URL ORIGIN_ACCESS_LOG [output-prefix]' >&2; exit 2; fi
for tool in ffmpeg ffprobe python3; do command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }; done
url=$1; log=$2; out=${3:-bench/results/lowerbound}
mkdir -p "$(dirname "$out")"
# Separate ffprobe metadata from the measured decode phase so both are auditable.
ffprobe -v error -show_streams -show_format -of json "$url" > "$out-probe.json"
start=$(python3 - "$log" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); print(sum(1 for _ in p.open()) if p.exists() else 0)
PY
)
ffmpeg -hide_banner -loglevel error -nostdin -i "$url" -map 0:v:0 -frames:v 1 -f null -
python3 - "$log" "$start" "$url" "$out" <<'PY'
import json,pathlib,sys,time
p=pathlib.Path(sys.argv[1]); start=int(sys.argv[2])
# Access logs are completed-request logs. Allow final connection close to flush.
time.sleep(.2)
rows=[json.loads(line) for line in p.read_text().splitlines()[start:]]
def count(r): return r.get('bytes',r.get('size',0))
result=dict(url=sys.argv[3],requests=len(rows),bytes=sum(count(r) for r in rows),requests_detail=rows,meaning='ffmpeg network read-ahead until one decoded frame; upper estimate of decodable-start bytes, not a mathematical minimum')
pathlib.Path(sys.argv[4]+'-decode.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:v for k,v in result.items() if k!='requests_detail'},indent=2))
PY
