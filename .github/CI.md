# Public CI

Each job in `workflows/pull-request.yml` keeps its ten-minute timeout. The unit
script keeps a 420-second build cap, a 240-second test cap, and a 540-second total
cap. Unit external commands run under a monotonic Python watchdog: build and
test deadlines are the smaller of their cap and the remaining total allowance.
Thirty seconds of the total are reserved for termination, owned-device cleanup
and result extraction. A timeout fails with status 124, sends TERM only to that
command's new process group, then KILL after at most five seconds if the owned
leader remains unreaped. Once the leader is reaped, no further group signal or
probe is attempted; residual descendants are not claimed verified. Cleanup
errors are retained and cannot turn a failed command into success. Original
nonzero command exits and handled interrupt statuses are preserved. Apps/checks
retain their existing shared helper and post-command budget checks.

The unit job builds the full `HotMicPlayerTests` target for a generic iOS
simulator before creating or booting a device. `ARCHS` selects the host's native
`arm64` or `x86_64` slice for both build and test; the test destination explicitly
selects that architecture. This avoids device-specific destination selection
during compilation and leaves the simulator shut down until needed. Steps stay
sequential. The selected installed iOS runtime need not match the SDK version;
Xcode 26.6 remains required, and normal deployment-target/runtime compatibility
checks still apply. The script neither downloads runtimes nor retries failures.

The script creates and cleans up only its own simulator by default. An explicit
`SIMULATOR_UDID` is borrowed and is never shut down or deleted by cleanup. A
failed build creates no device. Owned devices are shut down and deleted on normal
exit, command failure, or handled interruption; deletion failure fails the run.
Each cleanup command and result extraction has a five-second deadline and
one-second TERM grace, still capped by the remaining total allowance. Simulator
creation and boot stay sequential in the parent shell so ownership survives
interrupts. The runner's hard termination cannot guarantee shell cleanup or
artifact upload, even with `always()`.

Unit build caches use the `derived-unit-v2` prefix, host architecture, Xcode build,
package resolution, and source hash. Prefix restores allow incremental source
builds within that compatibility boundary. The local compatibility stamp also
rejects old or unstamped build products. The first v2 hosted run is a cold cache
run; a passing warm-cache retry is insufficient acceptance evidence.

`simulator-build.log` includes Xcode's build timing summary. Selected test progress,
build timing categories, 15-second heartbeats, last output, deadlines and exit
statuses appear in workflow output while commands run. Raw merged stdout/stderr,
per-command timing/deadline/status JSON, lifecycle status and the result bundle
are uploaded on success, failure and cancellation with `always()` and seven-day
retention; DerivedData is excluded. Result extraction prints actual executed,
passed, failed and skipped counts from xcresult on a green run, with raw summary
JSON in `result-summary.log`. Empty results, failures, skipped tests or inconsistent
counts fail validation; no expected test count is hard-coded. An interrupted/incomplete bundle may not yield
counts; retained progress/logs then identify the last observed runner stage.
Timing changes
need a fresh exact-head hosted cohort within the existing budgets, with cache
status recorded. Generic builds do not reduce test selection: CI still runs the
entire iOS unit target, including native-player tests.
