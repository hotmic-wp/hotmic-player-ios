#!/usr/bin/env python3
"""Headless Mac runner; callable over SSH from Linux. No Xcode GUI required."""
import argparse,json,os,pathlib,plistlib,shutil,subprocess,sys,time

def main():
    p=argparse.ArgumentParser(); p.add_argument('--xctestrun',required=True); p.add_argument('--destination',required=True,help='Simulator or physical device UDID'); p.add_argument('--simulator',action='store_true'); p.add_argument('--output',default='bench/results'); p.add_argument('--set',action='append',default=[],metavar='HM_NAME=value'); a=p.parse_args()
    if sys.platform!='darwin': raise SystemExit('Device runs require a remote Mac. Invoke this CLI over SSH; encoding, origin and analysis run on Linux.')
    env={k:v for k,v in os.environ.items() if k.startswith('HM_')}
    for pair in a.set:
        k,sep,v=pair.partition('=')
        if not sep or not k.startswith('HM_'): raise SystemExit('--set requires HM_NAME=value')
        env[k]=v
    env.setdefault('HM_BUILD_SHA',subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip())
    env.setdefault('HM_RUN_ID',time.strftime('%Y%m%d-%H%M%S')); env.setdefault('HM_SCRIPT','normal')
    source=pathlib.Path(a.xctestrun).resolve(); run_id=env['HM_RUN_ID']
    if not run_id or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_' for c in run_id): raise SystemExit('run id must be alphanumeric, dash or underscore')
    spec=plistlib.loads(source.read_bytes())
    def inject(obj):
        if isinstance(obj,dict):
            if obj.get('IsUITestBundle') or 'TestBundlePath' in obj:
                obj.setdefault('EnvironmentVariables',{}).update(env)
            for v in obj.values(): inject(v)
        elif isinstance(obj,list):
            for v in obj: inject(v)
    inject(spec)
    # Keep __TESTROOT__ relative paths valid.
    configured=source.with_name(f'hotmic-{run_id}.xctestrun'); configured.write_bytes(plistlib.dumps(spec))
    out=pathlib.Path(a.output).resolve(); out.mkdir(parents=True,exist_ok=True)
    result=out/f'{run_id}.xcresult'
    if result.exists(): raise SystemExit(f'Result already exists: {result}; use a fresh run id')
    began=time.monotonic()
    try:
        with (out/f'{run_id}.log').open('w') as log:
            code=subprocess.call(['xcodebuild','test-without-building','-xctestrun',str(configured),'-destination',f'id={a.destination}','-parallel-testing-enabled','NO','-resultBundlePath',str(result)],stdout=log,stderr=subprocess.STDOUT)
        if a.simulator:
            container=pathlib.Path(subprocess.check_output(['xcrun','simctl','get_app_container',a.destination,'com.hotmic.HotMicPlayerDemo','data'],text=True).strip())
            # A grid generates per-cell IDs with its own session suffix.
            for file in (container/'Documents/BenchRuns').glob('*.jsonl'): shutil.copy2(file,out/file.name)
        else:
            subprocess.run(['xcrun','devicectl','device','copy','from','--device',a.destination,'--domain-type','appDataContainer','--domain-identifier','com.hotmic.HotMicPlayerDemo','--source','Documents/BenchRuns','--destination',str(out/'device-files'/run_id)],check=True)
        (out/f'{run_id}-timing.json').write_text(json.dumps(dict(wall_seconds=time.monotonic()-began,exit_code=code,environment=env),indent=2)+'\n')
        print(f'{run_id}: exit {code}, wall {time.monotonic()-began:.1f}s; {out}',flush=True)
        return code
    finally: configured.unlink(missing_ok=True)
if __name__=='__main__': sys.exit(main())
