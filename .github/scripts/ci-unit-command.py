#!/usr/bin/env python3
"""Run one external unit-CI command with a deadline and an owned process group.

Exit status: the command's own status; 124 when its deadline passed; 123 when
--stall-seconds of silence passed before any --stall-until line; 125 for
watchdog-side errors; 128+N for a handled signal."""
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
    parser.add_argument("--reserve", type=float, default=35)
    parser.add_argument("--grace", type=float, default=5)
    parser.add_argument("--cancel-file", type=Path,
                        help="Parent-owned cancellation request; avoids signaling a completed background watchdog PID")
    parser.add_argument("--failure-file", type=Path,
                        help="Stop when a concurrent prerequisite records failure")
    parser.add_argument("--stall-seconds", type=float, default=0,
                        help="Exit 123 after this many seconds without output, until a --stall-until line appears")
    parser.add_argument("--stall-until", metavar="REGEX",
                        help="Output matching this disarms stall detection: the command is making progress")
    parser.add_argument("--finish-pattern", metavar="REGEX",
                        help="Output matching this means the command is finalizing its results")
    parser.add_argument("--finish-grace", type=float, default=0,
                        help="Seconds past --seconds allowed after --finish-pattern, still within the total deadline")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command or args.seconds <= 0 or args.grace < 0 or args.reserve < 0:
        parser.error("a command, positive seconds and nonnegative grace/reserve are required")
    if args.stall_seconds < 0 or args.finish_grace < 0:
        parser.error("stall seconds and finish grace must be nonnegative")
    stall_regex = re.compile(args.stall_until) if args.stall_until else None
    finish_regex = re.compile(args.finish_pattern) if args.finish_pattern else None

    began = time.monotonic()
    deadline = min(began + args.seconds, args.total_deadline - args.reserve)
    record = dict(command=command, started_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                  budget_seconds=args.seconds, total_deadline=args.total_deadline,
                  reserve_seconds=args.reserve, deadline=deadline,
                  available_seconds=max(0, deadline - began), grace_seconds=args.grace,
                  stall_seconds=args.stall_seconds, stalled=False,
                  finish_grace_seconds=args.finish_grace, finish_seen_after=None,
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
    # Stall detection stays armed until the command shows the progress named by
    # --stall-until; after that, long silences belong to the command itself.
    stall_armed = args.stall_seconds > 0
    finish_seen = None

    def progress(reader):
        nonlocal partial, timing_summary, stall_armed, finish_seen
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
            if stall_armed and stall_regex is not None and stall_regex.search(line):
                stall_armed = False
                say(f"progress observed after {time.monotonic() - began:.1f}s; stall detection disarmed")
            if finish_seen is None and finish_regex is not None and finish_regex.search(line):
                finish_seen = time.monotonic()
                record["finish_seen_after"] = finish_seen - began
                if args.finish_grace > 0:
                    say(f"results finalizing after {finish_seen - began:.1f}s; up to {args.finish_grace:g}s past the cap allowed")
            if "Build Timing Summary" in line:
                timing_summary = True
            if timing_summary or re.search(r"Test (Suite|Case)|Executed \d+|[◇✔✘↳]|\*\* (TEST|BUILD)|Result bundle|Testing (started|failed)| \| [\d.]+ seconds", line):
                say(line[:2000])
        return True

    args.log.parent.mkdir(parents=True, exist_ok=True)
    # Persist actual argv/deadline before launch, even if the parent is killed.
    args.log.with_suffix(".json").write_text(json.dumps(record, indent=2) + "\n")
    process = None
    cleanup_attempted = False
    status = 125

    def finish_command():
        """Signal only while the owned leader has not been reaped; bound waits."""
        errors = []
        record["residual_group_verified"] = False
        try:
            if process.poll() is not None:
                record["group_cleanup"] = "leader reaped; no further group signals"
            else:
                os.killpg(process.pid, signal.SIGTERM)
                say("TERM sent to owned command group")
                try:
                    process.wait(timeout=args.grace)
                    record["group_cleanup"] = "leader reaped after TERM; residual group unverified"
                    say(record["group_cleanup"])
                except subprocess.TimeoutExpired:
                    # wait timed out without reaping the leader, so its PID is
                    # still reserved. Never probe or signal after a reaped exit.
                    if process.returncode is None:
                        os.killpg(process.pid, signal.SIGKILL)
                        record["group_cleanup"] = "KILL sent while owned leader unreaped"
                        say(record["group_cleanup"])
        except ProcessLookupError:
            record["group_cleanup"] = "group no longer found; no signal retry"
        except OSError as error:
            errors.append(f"owned group cleanup: {error}")
        finally:
            if process.returncode is None:
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
                last_output = began
                while True:
                    if progress(reader):
                        last_output = time.monotonic()
                    now = time.monotonic()
                    code = process.poll()
                    # Once results are being written, finishing them may run
                    # past the cap; the total deadline and reserve still bind.
                    effective_deadline = deadline
                    if finish_seen is not None and args.finish_grace > 0:
                        effective_deadline = max(deadline, min(began + args.seconds + args.finish_grace,
                                                               args.total_deadline - args.reserve))
                    # Preserve an observed command failure before a concurrent
                    # prerequisite failure can replace its exit status.
                    if code is not None and code != 0 and received is None:
                        status = code if code >= 0 else 128 - code
                        break
                    if code is None and args.cancel_file is not None and args.cancel_file.exists() and received is None:
                        received = signal.SIGTERM
                    if received is not None:
                        status = 128 + received
                        break
                    if args.failure_file is not None:
                        try:
                            dependency = json.loads(args.failure_file.read_text())
                        except (OSError, ValueError):
                            dependency = {}
                        if dependency.get("exit_code", 0) != 0:
                            status = dependency["exit_code"]
                            record["dependency_exit"] = status
                            break
                    if code is not None and code != 0:
                        status = code if code >= 0 else 128 - code
                        break
                    if code is None and stall_armed and now - last_output >= args.stall_seconds:
                        record["stalled"] = True
                        status = 123
                        say(f"no output for {now - last_output:.0f}s and no progress yet; treating the command as stalled")
                        break
                    if now >= effective_deadline:
                        record["timed_out"] = True
                        status = 124
                        break
                    if code is not None:
                        status = code if code >= 0 else 128 - code
                        break
                    if now >= heartbeat:
                        say(f"{now - began:.1f}s elapsed; {max(0, effective_deadline - now):.1f}s left; silent {now - last_output:.0f}s; last output: {recent[-1] if recent else '(none)'}")
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
        say(f"exit={status}; elapsed={record['elapsed_seconds']:.1f}s; timeout={record['timed_out']}; stalled={record['stalled']}; signal={received}")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
