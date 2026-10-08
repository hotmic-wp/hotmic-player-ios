#!/usr/bin/env python3
"""Zero-install Range origin, Python stdlib. Structured completed-request log."""
import argparse, http.server, json, mimetypes, pathlib, re, threading, time
from urllib.parse import unquote, urlsplit

class Origin(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def do_HEAD(self): self.serve(False)
    def do_GET(self): self.serve(True)
    def serve(self, body):
        began=time.monotonic(); sent=0; status=500; path=None
        try:
            path=(self.server.root/unquote(urlsplit(self.path).path).lstrip('/')).resolve()
            if not path.is_relative_to(self.server.root) or not path.is_file():
                status=404; self.send_error(status); return
            total=path.stat().st_size; start=0; end=total-1; status=200
            header=self.headers.get('Range')
            if header:
                m=re.fullmatch(r'bytes=(\d*)-(\d*)',header)
                if not m or not any(m.groups()):
                    status=416; self.send_error(status); return
                a,b=m.groups()
                if not a: start=max(0,total-int(b))
                else: start=int(a); end=min(end,int(b)) if b else end
                if start>=total or end<start or (not a and int(b)==0):
                    status=416; self.send_response(status); self.send_header('Content-Range',f'bytes */{total}'); self.send_header('Content-Length','0'); self.end_headers(); return
                status=206
            self.send_response(status)
            mime={'.m3u8':'application/vnd.apple.mpegurl','.m4s':'video/iso.segment'}.get(path.suffix,mimetypes.guess_type(str(path))[0] or 'application/octet-stream')
            self.send_header('Content-Type',mime); self.send_header('Content-Length',str(end-start+1)); self.send_header('Accept-Ranges','bytes')
            self.send_header('Cache-Control','public, max-age=3600, immutable' if path.suffix not in ('.json','.m3u8') else 'public, max-age=30')
            if status==206: self.send_header('Content-Range',f'bytes {start}-{end}/{total}')
            self.end_headers()
            if body:
                with path.open('rb') as f:
                    f.seek(start); remaining=end-start+1
                    while remaining:
                        block=f.read(min(64*1024,remaining))
                        if not block: break
                        self.wfile.write(block); remaining-=len(block); sent+=len(block)
        except (BrokenPipeError,ConnectionResetError): pass
        finally:
            row=dict(timestamp=time.time(),path=urlsplit(self.path).path,method=self.command,status=status,bytes=sent,range=self.headers.get('Range'),duration_ms=(time.monotonic()-began)*1000)
            with self.server.log_lock:
                with self.server.log.open('a') as f: f.write(json.dumps(row)+'\n')
    def log_message(self,*args): pass

def main():
    p=argparse.ArgumentParser(); p.add_argument('--root',default='bench/generated'); p.add_argument('--host',default='127.0.0.1'); p.add_argument('--port',type=int,default=8088); p.add_argument('--log',default='bench/results/origin.jsonl'); a=p.parse_args()
    s=http.server.ThreadingHTTPServer((a.host,a.port),Origin); s.root=pathlib.Path(a.root).resolve(); s.log=pathlib.Path(a.log); s.log.parent.mkdir(parents=True,exist_ok=True); s.log_lock=threading.Lock()
    print(f'Origin http://{a.host}:{a.port} -> {s.root}',flush=True)
    try: s.serve_forever()
    except KeyboardInterrupt: pass
    finally: s.server_close()
if __name__=='__main__': main()
