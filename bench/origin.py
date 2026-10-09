#!/usr/bin/env python3
"""Zero-install Range origin with optional shared payload rate and request latency."""
import argparse, http.server, json, mimetypes, pathlib, re, threading, time
from urllib.parse import unquote, urlsplit

class Origin(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def handle(self):
        try: super().handle()
        except (BrokenPipeError, ConnectionResetError): pass
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
            if self.server.latency: time.sleep(self.server.latency)
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
                        block=f.read(min(16*1024 if self.server.bandwidth else 64*1024,remaining))
                        if not block: break
                        bandwidth=self.server.bandwidth
                        if self.server.profile:
                            elapsed=(time.monotonic()-self.server.started)%self.server.period
                            bandwidth=next(rate for until,rate in self.server.profile if elapsed<until)
                        if bandwidth:
                            # One shared origin capacity across all connections, rather
                            # than multiplying bandwidth by prefetch concurrency.
                            with self.server.rate_lock:
                                self.server.next_send=max(time.monotonic(),self.server.next_send)+len(block)/bandwidth
                                ready=self.server.next_send
                            time.sleep(max(0,ready-time.monotonic()))
                        self.wfile.write(block); remaining-=len(block); sent+=len(block)
        except (BrokenPipeError,ConnectionResetError): pass
        finally:
            row=dict(connection=f"{self.client_address[0]}:{self.client_address[1]}",timestamp=time.time(),path=urlsplit(self.path).path,method=self.command,status=status,bytes=sent,range=self.headers.get('Range'),duration_ms=(time.monotonic()-began)*1000,bandwidth_bytes_s=self.server.bandwidth,bandwidth_profile=self.server.profile,origin_elapsed_s=time.monotonic()-self.server.started,latency_ms=self.server.latency*1000)
            with self.server.log_lock:
                with self.server.log.open('a') as f: f.write(json.dumps(row)+'\n')
    def log_message(self,*args): pass

def main():
    p=argparse.ArgumentParser(); p.add_argument('--root',default='bench/generated'); p.add_argument('--host',default='127.0.0.1'); p.add_argument('--port',type=int,default=8088); p.add_argument('--log',default='bench/results/origin.jsonl'); p.add_argument('--bandwidth-bytes-per-second',type=float,default=0,help='Shared media payload rate; 0 is unlimited'); p.add_argument('--latency-ms',type=float,default=0,help='Delay before each response header'); p.add_argument('--bandwidth-profile',default='',help='Repeating duration:bytes-per-second phases, e.g. 4:450000,4:550000'); a=p.parse_args()
    if not all(__import__('math').isfinite(v) and v>=0 for v in (a.bandwidth_bytes_per_second,a.latency_ms)): p.error('throttle values must be finite and nonnegative')
    profile=[]; period=0
    try:
        for phase in filter(None,a.bandwidth_profile.split(',')):
            duration,rate=map(float,phase.split(':'))
            if not all(__import__('math').isfinite(v) and v>0 for v in (duration,rate)): raise ValueError()
            period+=duration; profile.append((period,rate))
    except ValueError: p.error('profile requires positive finite duration:rate phases')
    s=http.server.ThreadingHTTPServer((a.host,a.port),Origin); s.root=pathlib.Path(a.root).resolve(); s.log=pathlib.Path(a.log); s.log.parent.mkdir(parents=True,exist_ok=True); s.log_lock=threading.Lock()
    s.bandwidth=a.bandwidth_bytes_per_second; s.latency=a.latency_ms/1000; s.rate_lock=threading.Lock(); s.next_send=0
    s.profile=profile; s.period=period; s.started=time.monotonic()
    print(f'Origin http://{a.host}:{a.port} -> {s.root}',flush=True)
    try: s.serve_forever()
    except KeyboardInterrupt: pass
    finally: s.server_close()
if __name__=='__main__': main()
