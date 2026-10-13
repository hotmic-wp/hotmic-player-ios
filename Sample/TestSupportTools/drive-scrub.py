#!/usr/bin/env python3
"""Drive the opt-in scrub cancellation test on one explicitly owned iOS simulator.

Run from the repository root with --simulator UDID --shot-dir NEW_DIRECTORY.
Uses only that simulator's Sample container and launches Settings there to background
Sample during a held press. No server, downloaded media or private tools are required.
Receipts include host command exit/wall time and app readiness/interaction/identity.
"""
import argparse
import json
import pathlib
import subprocess
import time

BUNDLE = 'com.hotmic.HotMicPlayerDemo'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator', required=True, help='Dedicated, caller-owned simulator UDID')
    parser.add_argument('--shot-dir', required=True, type=pathlib.Path, help='New absolute host output directory')
    parser.add_argument('--timeout', type=float, default=180, help='Total deadline in seconds')
    args = parser.parse_args()
    shots = args.shot_dir.resolve()
    shots.mkdir(parents=True, exist_ok=True)
    if list(shots.iterdir()):
        parser.error('--shot-dir must be empty (preserve previous runs in separate directories)')
    deadline = time.monotonic() + args.timeout
    started = time.time()
    log = shots / 'scrub-driver.jsonl'

    def record(event, **fields):
        with log.open('a') as output:
            output.write(json.dumps(dict(event=event, timestamp=time.time(), simulator=args.simulator) | fields, sort_keys=True) + '\n')

    def command(*tail, required=True):
        cmd = ['xcrun', 'simctl', *tail]
        before = time.monotonic()
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        record('host-command', argv=cmd, exit=result.returncode, wall=time.monotonic() - before,
               stdout=result.stdout, stderr=result.stderr)
        if result.returncode and required:
            raise RuntimeError(f'{cmd} failed: {result.stderr}')
        return result.stdout.strip()

    def read(path):
        try:
            return json.loads(path.read_text())
        except (OSError, ValueError):
            return {}

    def wait(description, predicate):
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            time.sleep(0.05)
        raise RuntimeError('Timed out waiting for ' + description)

    def receipt(name, **fields):
        payload = dict(success=True, simulator=args.simulator, timestamp=time.time(), **fields)
        target = shots / (name + '.json')
        temporary = target.with_suffix('.tmp')
        temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + '\n')
        temporary.replace(target)
        record(name, **payload)

    try:
        container = pathlib.Path(command('get_app_container', args.simulator, BUNDLE, 'data'))
        probe = container / 'Documents/HMProbe'
        # Ready for the test to launch a fresh app session; stale app receipts cannot qualify.
        receipt('scrub-driver-ready', container=str(container), started=started)
        # xcodebuild can replace the app's data container during installation. Resolve
        # it again until the newly launched session reports observer readiness.
        last_resolve = 0.0

        def fresh_ready():
            nonlocal container, probe, last_resolve
            if time.monotonic() - last_resolve >= 0.5:
                last_resolve = time.monotonic()
                current = command('get_app_container', args.simulator, BUNDLE, 'data', required=False)
                if current:
                    resolved = pathlib.Path(current)
                    if resolved != container:
                        record('app-container-replaced', before=str(container), after=str(resolved))
                    container = resolved
                    probe = container / 'Documents/HMProbe'
            value = read(probe / 'ready.json')
            return value if value.get('timestamp', 0) > started and value.get('commandsReady') else None

        ready = wait('fresh command observer readiness', fresh_ready)
        session = ready['session']
        record('app-ready', receipt=ready)

        def status():
            value = read(probe / 'status.json')
            return value if value.get('session') == session else {}

        for signal, action in [('scrub-next', 'next'), ('scrub-hold', 'background')]:
            path = shots / (signal + '.signal')
            wait(signal + ' signal', path.exists)
            signal_time = path.stat().st_mtime
            held = wait('held scrub interaction', lambda: (s if (s := status()).get('interacting') and
                        s.get('timestamp', 0) >= signal_time and s.get('applicationState') == 0 else None))
            record('held-interaction', signal=signal, receipt=held)
            if action == 'next':
                command('spawn', args.simulator, 'notifyutil', '-p', 'com.hotmic.probe.next')
                received = wait('next command receipt during hold', lambda: (r if (r := read(probe / 'command.json')).get('session') == session
                                and r.get('command') == 'next' and r.get('beforeInteracting') is True
                                and r.get('timestamp', 0) >= held['timestamp'] else None))
                changed = wait('next item displayed during hold', lambda: (s if (s := status()).get('itemID') != held['itemID']
                               and s.get('index') == held['index'] + 1 and s.get('frameReady') else None))
                receipt(signal, held=held, command=received, after=changed)
            else:
                command('launch', args.simulator, 'com.apple.Preferences')
                background = wait('actual app background entry', lambda: (r if (r := read(probe / 'background.json')).get('session') == session
                                  and held['timestamp'] <= r.get('timestamp', 0) < held['timestamp'] + 5
                                  and r.get('applicationState') == 2 else None))
                receipt(signal, held=held, background=background)
        record('complete', success=True)
    except Exception as error:
        record('failed', error=str(error))
        raise


if __name__ == '__main__':
    main()
