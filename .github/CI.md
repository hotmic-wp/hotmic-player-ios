# Public CI

The apps and checks jobs in `workflows/pull-request.yml` keep their ten-minute
timeout; the unit job has twelve minutes. The unit script has a 420-second build
cap, a 300-second cap per test attempt, and a 660-second total cap. Unit external commands run under a monotonic Python watchdog: build and
test deadlines are the smaller of their cap and the remaining total allowance.
Thirty-five seconds of the total are reserved for termination, owned-device cleanup
and result extraction. A timeout fails with status 124, sends TERM only to that
command's new process group, then KILL after at most five seconds if the owned
leader remains unreaped. Once the leader is reaped, no further group signal or
probe is attempted; residual descendants are not claimed verified. Cleanup
errors are retained and cannot turn a failed command into success. Original
nonzero command exits and handled interrupt statuses are preserved. Apps/checks
retain their existing shared helper and post-command budget checks.

The unit job builds and tests the `HotMicPlayerTests` scheme of the test-only
`Tests/HotMicPlayerTestHost` project. Its `HotMicPlayerTests` bundle compiles the
package's existing test sources and copies the same `Fixtures` folder, links the
local `HotMicPlayer`/`HotMicPlayerUI` products, and is injected (`TEST_HOST`) into an
empty UIKit app launched through `UIApplicationMain` with a connected window scene.
The host starts no media or services; it writes `[test-host]` launch receipts, and
native tests check, without waiting, that they run in that launched host. The
package's own `HotMicPlayerTests` target and resources are unchanged.

The unit job runs one generic `build-for-testing` of the host app and the full
`HotMicPlayerTests` bundle under its own background watchdog. While it compiles,
the parent discovers a runtime, creates and boots its owned simulator and awaits
`bootstatus` readiness, so first-boot data migration (50 to 65 seconds on hosted
runners) overlaps compilation. Those simulator steps stop early with the build's
status if the build records a failure. After the build succeeds, it validates exactly one current compatible generated
`.xctestrun` and captures its path/hash, unmodified copy, app/test executable and
resource hashes, and frozen Git/tracked-source bindings. Before building, only
old generated top-level test specifications are removed so stale specifications
cannot survive an incremental build; cached compiled products remain compatible
with v3. Validation requires the observed format-1 HotMicPlayerTests app-hosted
target, expected host/test bundle identities and paths inside this build, native
simulator binary slices and identical original Fixtures. Missing, ambiguous,
stale or incompatible inputs fail before any test host is installed.
After validation it warms up the test host and then runs the tests on the owned
device, one watchdog-bounded command at a time. Execution uses supported
`xcodebuild test-without-building -xctestrun <validated generated file>` with the
explicit native destination, target-only selection, parallel testing disabled and
result bundle. It supplies no project, scheme, derived-data path or build settings
at execution, so it consumes compiled products directly. A failed or timed-out build exits
with its original status before any test runs; an owned simulator created
meanwhile is shut down and deleted by cleanup. An
interrupt during the build requests compiler cancellation through an owned file
and reaps the compiler watchdog before cleanup; only that watchdog signals its
unreaped child group, and the shell never signals a possibly completed
background PID. An interrupt during a later step is forwarded to that step's
watchdog before cleanup. `bootstatus` is bounded by the remaining total
allowance and cleanup reserve, so a migration slower than compilation leaves
less time for tests. `ARCHS` selects the host's native
`arm64` or `x86_64` slice for the build; the test destination explicitly
selects that architecture. This avoids device-specific destination selection
during compilation. The selected installed iOS runtime need not match the SDK version;
Xcode 26.6 remains required, and normal deployment-target/runtime compatibility
checks still apply. The script never downloads runtimes. Discovery allows
60 seconds for cold CoreSimulator initialization (the prior 30-second cap timed
out on a hosted runner) and remains subject to the same global deadline and
35-second cleanup reserve.

A freshly created simulator can report `bootstatus` Finished before it launches
apps reliably. On hosted runners, `xcodebuild` then installed the test host,
logged its launch request and produced no further output until the test cap
killed it, leaving a result bundle with no `Info.plist`. Launches issued 100
seconds or more after Finished succeeded; launches at 56 to 78 seconds hung.
Two measures handle this. First, after validation the script installs the
compiled host app with `simctl install` and launches it with `simctl launch`,
up to three 30-second attempts, then terminates it. This warm-up is best effort
and only warns on failure. Second, the test run's watchdog treats 120 seconds
without output, before any host-process or test output appears, as a stalled
launch and exits 123. Healthy runs were seen silent for up to 91 seconds before
their first output. After a stall the script terminates the host and runs the
tests once more if at least 180 seconds of the total allowance remain;
otherwise it fails with 123. Real test failures, timeouts after tests started
and every other status are never retried. Once `xcodebuild` prints
`** TEST EXECUTE SUCCEEDED **` or `** TEST EXECUTE FAILED **`, the watchdog
allows up to 30 seconds past the attempt cap, still within the total
deadline, so the result bundle is finalized and failing runs report counts. A
bundle left without `Info.plist` is reported as incomplete instead of being
passed to `xcresulttool`.

The script creates and cleans up only its own simulator by default. An explicit
`SIMULATOR_UDID` is borrowed and is never shut down or deleted by cleanup.
Build failures, later failures and handled interruptions attempt owned UUID
cleanup within the remaining budgets. Owned devices are shut down and deleted on normal
exit, command failure, or handled interruption; deletion failure fails the run.
Shutdown, deletion and result extraction each have a ten-second deadline, with
one-second TERM grace each, still capped by the remaining total allowance. These
three caps plus three one-second graces allocate 33 seconds of the 35-second reserve; the extra five
seconds reduce foreground allowance within the 660-second total. Simulator
creation and boot stay sequential in the parent shell so ownership survives
interrupts. The create log is cleared before creation starts, so interrupted
reuse cannot adopt an earlier invocation's UUID. The runner's hard termination cannot guarantee shell cleanup or
artifact upload, even with `always()`.

Unit build caches use the `derived-unit-v3` prefix, host architecture, Xcode build,
package resolution, and source hash. Prefix restores allow incremental source
builds within that compatibility boundary. The local compatibility stamp also
rejects old, package-scheme or unstamped build products. The first v3 hosted run
is a cold cache run; a passing warm-cache retry is insufficient acceptance evidence.

`simulator-build.log` includes Xcode's build timing summary. Selected test progress,
build timing categories, 15-second heartbeats, last output, deadlines and exit
statuses appear in workflow output while commands run. Raw merged stdout/stderr,
per-command timing/deadline/status JSON, compiled-product/source bindings, selected
original `.xctestrun`, lifecycle status and the result bundle
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
