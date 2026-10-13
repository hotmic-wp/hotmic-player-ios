#!/usr/bin/env python3
"""Run one external unit-CI command with a deadline and an owned process group."""
import argparse
from collections import deque
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--seconds", type=float, required=True)
    parser.add_argument("--total-deadline", type=float, required=True)
    parser.add_argument("--reserve", type=float, default=30)
    parser.add_argument("--grace", type=float, default=5)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command or args.seconds <= 0 or args.grace < 0 or args.reserve < 0:
        parser.error("a command, positive seconds and nonnegative grace/reserve are required")

    began = time.monotonic()
    deadline = min(began + args.seconds, args.total_deadline - args.reserve)
    record = dict(command=command, started_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                  budget_seconds=args.seconds, total_deadline=args.total_deadline,
                  reserve_seconds=args.reserve, deadline=deadline,
                  available_seconds=max(0, deadline - began), grace_seconds=args.grace,
                  timed_out=False, received_signal=None, pid=None, command_exit=None)
    received = None

    def interrupted(signum, _frame):
        nonlocal received
        if received is None:
            received = signum

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, interrupted)

    def say(message):
        print(f"[{args.name}] {message}", flush=True)

    recent = deque(maxlen=12)
    partial = ""
    timing_summary = False

    def progress(reader):
        nonlocal partial, timing_summary
        # Read at most 64 KiB per poll: noisy output cannot starve deadline checks.
        data = reader.read(65536)
        if not data:
            return False
        lines = (partial + data.decode("utf-8", errors="replace")).split("\n")
        partial = lines.pop()[-4096:]
        for line in lines:
            line = line.rstrip("\r")
            if not line:
                timing_summary = False
                continue
            recent.append(line[-2000:])
            if "Build Timing Summary" in line:
                timing_summary = True
            if timing_summary or re.search(r"Test (Suite|Case)|Executed \d+|[◇✔✘↳]|\*\* (TEST|BUILD)|Result bundle|Testing (started|failed)| \| [\d.]+ seconds", line):
                say(line[:2000])
        return True

    args.log.parent.mkdir(parents=True, exist_ok=True)
    process = None
    cleanup_attempted = False
    status = 125

    def finish_command():
        """Attempt each group signal once; always reap even if a signal fails."""
        errors = []
        try:
            os.killpg(process.pid, signal.SIGTERM)
            say("TERM sent to owned command group")
            # Do not probe with killpg(..., 0), or reap the leader during grace.
            # Keep its PID reserved until the final group signal when possible.
            time.sleep(args.grace)
            os.killpg(process.pid, signal.SIGKILL)
            say("KILL sent to owned command group after grace")
        except ProcessLookupError:
            pass
        except OSError as error:
            errors.append(f"owned group cleanup: {error}")
        finally:
            try:
                process.wait(timeout=1)
            except (subprocess.TimeoutExpired, OSError) as error:
                errors.append(f"owned command reap: {error}")
            record["command_exit"] = process.returncode
        if errors:
            record["cleanup_errors"] = errors
            for error in errors:
                say(error)
        return bool(errors)

    say(f"deadline in {record['available_seconds']:.1f}s (command cap {args.seconds:g}s; total reserve {args.reserve:g}s)")
    try:
        with args.log.open("wb") as output, args.log.open("rb") as reader:
            if deadline <= began:
                record["timed_out"] = True
                status = 124
                say("remaining total budget exhausted; command was not launched")
            elif received is None:
                process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT,
                                           start_new_session=True)
                record["pid"] = process.pid
                heartbeat = began + 15
                while True:
                    progress(reader)
                    now = time.monotonic()
                    code = process.poll()
                    if received is not None:
                        status = 128 + received
                        break
                    if code is not None and code != 0:
                        status = code if code >= 0 else 128 - code
                        break
                    if now >= deadline:
                        record["timed_out"] = True
                        status = 124
                        break
                    if code is not None:
                        status = code if code >= 0 else 128 - code
                        break
                    if now >= heartbeat:
                        say(f"{now - began:.1f}s elapsed; {max(0, deadline - now):.1f}s left; last output: {recent[-1] if recent else '(none)'}")
                        heartbeat = now + 15
                    time.sleep(0.1)

                # Only this child's new session/process group is ever signaled.
                cleanup_attempted = True
                if finish_command() and status == 0:
                    status = 125
                drain_deadline = time.monotonic() + 1
                while time.monotonic() < drain_deadline and progress(reader):
                    pass  # Raw output stays on disk even if the progress drain is capped.
                if partial:
                    recent.append(partial[-2000:])
            else:
                status = 128 + received
    except OSError as error:
        say(f"command launch/log error: {error}")
        record["error"] = str(error)
        if status == 0:
            status = 125
    finally:
        if process is not None and not cleanup_attempted:
            if finish_command() and status == 0:
                status = 125
        if received is not None and status == 0:
            status = 128 + received
        record["received_signal"] = received
        record["finished_utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        record["exit_code"] = status
        record["elapsed_seconds"] = time.monotonic() - began
        args.log.with_suffix(".json").write_text(json.dumps(record, indent=2) + "\n")
        if status:
            say("last raw output (also retained in log):")
            for line in recent:
                say(line)
        say(f"exit={status}; elapsed={record['elapsed_seconds']:.1f}s; timeout={record['timed_out']}; signal={received}")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
