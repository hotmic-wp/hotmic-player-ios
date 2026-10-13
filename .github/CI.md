# Public CI

Each job in `workflows/pull-request.yml` keeps its ten-minute timeout. The unit
script keeps a 420-second build cap, a 240-second test cap, and a 540-second total
cap. A successful command that exceeds its cap still fails the job.

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
The runner's hard termination cannot guarantee shell cleanup.

Unit build caches use the `derived-unit-v2` prefix, host architecture, Xcode build,
package resolution, and source hash. Prefix restores allow incremental source
builds within that compatibility boundary. The local compatibility stamp also
rejects old or unstamped build products. The first v2 hosted run is a cold cache
run; a passing warm-cache retry is insufficient acceptance evidence.

`simulator-build.log` includes Xcode's build timing summary. Simulator, build,
and test logs plus the result bundle are uploaded on failure. Timing changes
need a fresh exact-head hosted cohort within the existing budgets, with cache
status recorded. Generic builds do not reduce test selection: CI still runs the
entire iOS unit target, including native-player tests.
