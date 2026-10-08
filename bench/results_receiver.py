#!/usr/bin/env python3
"""Stdlib-only JSONL receiver. Runs on Linux/macOS; bind to an owned interface.
POST /runs, X-HotMic-Run-ID. Idempotent identical re-uploads, reject conflicts.
"""
import argparse,hashlib,http.server,json,pathlib,re,tempfile,threading

class Receiver(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def do_POST(self):
        if self.path!='/runs': self.reply(404,{'error':'POST /runs'}); return
        try:
            length=int(self.headers.get('Content-Length','-1'))
            if not 0<length<=self.server.max_bytes: self.reply(413,{'error':'invalid/oversize Content-Length'}); return
            raw=self.rfile.read(length)
            if len(raw)!=length or not raw.endswith(b'\n'): raise ValueError('incomplete JSONL')
            rows=[json.loads(line) for line in raw.splitlines()]
            header=rows[0]; run_id=header.get('run_id','')
            if header.get('type')!='runHeader' or not re.fullmatch(r'[A-Za-z0-9_-]{1,240}',run_id): raise ValueError('invalid header/run_id')
            if self.headers.get('X-HotMic-Run-ID')!=run_id: raise ValueError('header run ID mismatch')
            if sum(r.get('event')=='runEnd' for r in rows[1:])!=1: raise ValueError('missing/duplicate runEnd')
            path=self.server.root/(run_id+'.jsonl')
            with self.server.lock:
                if path.exists():
                    if path.read_bytes()!=raw: self.reply(409,{'error':'run ID already exists with different bytes'}); return
                else:
                    with tempfile.NamedTemporaryFile(dir=self.server.root,delete=False) as f: f.write(raw); temporary=pathlib.Path(f.name)
                    temporary.replace(path)
            self.reply(201,{'run_id':run_id,'bytes':length,'sha256':hashlib.sha256(raw).hexdigest()})
        except (ValueError,json.JSONDecodeError,UnicodeDecodeError) as error: self.reply(400,{'error':str(error)})
    def reply(self,code,body):
        data=json.dumps(body).encode(); self.send_response(code); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.send_header('Connection','close'); self.end_headers(); self.wfile.write(data); self.close_connection=True
    def log_message(self,format,*args): print(format%args,flush=True)

def main():
    p=argparse.ArgumentParser(); p.add_argument('--host',default='127.0.0.1'); p.add_argument('--port',type=int,default=8090); p.add_argument('--output',default='bench/results/received'); p.add_argument('--max-bytes',type=int,default=64*1024*1024); a=p.parse_args()
    root=pathlib.Path(a.output).resolve(); root.mkdir(parents=True,exist_ok=True)
    s=http.server.ThreadingHTTPServer((a.host,a.port),Receiver); s.root=root; s.max_bytes=a.max_bytes; s.lock=threading.Lock()
    print(f'Receiver http://{a.host}:{a.port}/runs -> {root}',flush=True)
    try: s.serve_forever()
    except KeyboardInterrupt: pass
    finally: s.server_close()
if __name__=='__main__': main()
