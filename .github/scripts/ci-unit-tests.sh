#!/bin/bash
# Package tests only. Complete generic build, then create/boot and await the simulator.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
source .github/scripts/ci-common.sh
validation_dir="${VALIDATION_DIR:-.bench/unit}"
mkdir -p "$validation_dir"
derived="$validation_dir/DerivedData"
# Test-only project: the package's test sources and Fixtures, linked against the
# local package and injected into an empty UIKit app host (TEST_HOST).
test_project=Tests/HotMicPlayerTestHost/HotMicPlayerTestHost.xcodeproj
started=$SECONDS
job_name=unit-tests
budget_total=540
budget_simulator_build=420
budget_unit_tests=240
# Reserve 35s for bounded termination, cleanup and result extraction, leaving
# another 60s outside this script for upload within the ten-minute job.
total_deadline=$(python3 -c 'import time; print(time.monotonic() + 540)')
watchdog_pid=""
build_watchdog_pid=""
simulator_id="${SIMULATOR_UDID:-}"
created_simulator=0
creating_simulator=0
unit_step() {
  local name="$1" budget="$2" status=0
  local failure_args=()
  if [ -n "$build_watchdog_pid" ]; then
    failure_args=(--failure-file "$validation_dir/simulator-build.json")
  fi
  shift 2
  echo "::group::$name"
  python3 .github/scripts/ci-unit-command.py --name "$name" \
    --log "$validation_dir/$name.log" --seconds "$budget" \
    --total-deadline "$total_deadline" --reserve "${command_reserve:-35}" \
    --grace "${command_grace:-5}" ${failure_args[@]+"${failure_args[@]}"} -- "$@" &
  watchdog_pid=$!
  wait "$watchdog_pid" || status=$?
  watchdog_pid=""
  echo "::endgroup::"
  return "$status"
}
stop_build() {
  if [ -n "$build_watchdog_pid" ]; then
    # A finished background PID may already have been reaped by bash. Request
    # cancellation through an owned file; only the watchdog signals its child.
    touch "$validation_dir/build-cancel"
    wait "$build_watchdog_pid" || true
    build_watchdog_pid=""
  fi
}
interrupt() {
  trap '' INT TERM HUP
  if [ -n "$watchdog_pid" ]; then
    kill -s "$1" "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" || true
    watchdog_pid=""
  fi
  stop_build
  exit "$2"
}
read_created_simulator() {
  local line
  while IFS= read -r line; do
    if [[ "$line" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
      simulator_id="$line"
      created_simulator=1
      return 0
    fi
  done < "$validation_dir/simulator-create.log"
  return 1
}
cleanup() {
  local status=$? summary_status=0
  trap - EXIT
  trap '' INT TERM HUP
  # Reap the independently owned compiler before simulator cleanup on every exit.
  stop_build
  # Recover an emitted create UUID if interrupted before the parent assignment.
  if [ "$creating_simulator" = 1 ] && [ -s "$validation_dir/simulator-create.log" ]; then
    read_created_simulator || true
  fi
  command_reserve=0
  command_grace=1
  # Shutdown/delete/summary caps plus 1s grace each use 33s of the 35s reserve.
  if [ "$created_simulator" = 1 ]; then
    unit_step simulator-shutdown 10 xcrun simctl shutdown "$simulator_id" || true
    if ! unit_step simulator-delete 10 xcrun simctl delete "$simulator_id"; then
      echo "::error::Could not delete owned simulator $simulator_id."
      [ "$status" != 0 ] || status=1
    fi
  fi
  if [ -d "$validation_dir/UnitTests.xcresult" ]; then
    unit_step result-summary 10 xcrun xcresulttool get test-results summary \
      --path "$validation_dir/UnitTests.xcresult" || summary_status=$?
    if [ "$summary_status" = 0 ]; then
      python3 - "$validation_dir/result-summary.log" <<'PY' || summary_status=$?
import json
import sys
with open(sys.argv[1]) as source:
    summary = json.load(source)
total, skipped, passed, failed = (summary[key] for key in
                                ("totalTestCount", "skippedTests", "passedTests", "failedTests"))
print(f"Full-target results: total={total}, executed={total - skipped}, passed={passed}, failed={failed}, skipped={skipped}")
if not all(isinstance(value, int) and value >= 0 for value in (total, skipped, passed, failed)):
    sys.exit("Invalid unit-result counts")
if total <= 0 or skipped != 0 or failed != 0 or passed != total:
    sys.exit("Unit results require executed tests, no failures and no skips")
PY
    fi
    # A green run must include observable executed/skipped counts.
    [ "$status" != 0 ] || status=$summary_status
  elif [ "$status" = 0 ]; then
    echo "::error::No unit result bundle; executed/skipped counts unavailable."
    status=1
  fi
  printf 'exit=%s\nowned=%s\nsimulator=%s\ntotal_seconds=%s\n' \
    "$status" "$created_simulator" "$simulator_id" "$((SECONDS - started))" \
    > "$validation_dir/lifecycle.txt"
  echo "unit-tests: $((SECONDS - started))s total including cleanup; exit=$status"
  exit "$status"
}
trap cleanup EXIT
trap 'interrupt INT 130' INT
trap 'interrupt TERM 143' TERM
trap 'interrupt HUP 129' HUP
simulator_arch=$(uname -m)
case "$simulator_arch" in
  arm64|x86_64) ;;
  *) echo "Unsupported simulator host architecture: $simulator_arch" >&2; exit 1 ;;
esac
# Drop restored products when the toolchain or package resolution changed.
# Source-only restores stay on disk so the compile is incremental.
package_fingerprint() {
  local files=(Package.swift) path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    files+=("$path")
  done <<EOF
$(find . \( -name .git -o -name .bench \) -prune -o -name Package.resolved -print | sort)
EOF
  shasum -a 256 "${files[@]}" | shasum -a 256 | awk '{print $1}'
}
prepare_cached_products() {
  local xcode_id packages stamp old_xcode old_packages old_build_mode
  unit_step toolchain 15 xcodebuild -version
  xcode_id=$(awk 'END { print $NF }' "$validation_dir/toolchain.log")
  packages=$(package_fingerprint)
  stamp="$derived/Build/.ci-stamp"
  if [ -f "$stamp" ]; then
    old_xcode=$(sed -n '1p' "$stamp")
    old_packages=$(sed -n '2p' "$stamp")
    old_build_mode=$(sed -n '3p' "$stamp")
    if [ "$old_xcode" != "$xcode_id" ] || [ "$old_packages" != "$packages" ] || [ "$old_build_mode" != "app-hosted-simulator-v1:$simulator_arch" ]; then
      echo "Removing cached products: toolchain, package resolution, or simulator build mode changed."
      rm -rf "$derived/Build" "$derived/ModuleCache.noindex" "$derived/SourcePackages"
    fi
  elif [ -d "$derived/Build" ]; then
    echo "Removing cached products without a compatibility stamp."
    rm -rf "$derived/Build" "$derived/ModuleCache.noindex" "$derived/SourcePackages"
  fi
  mkdir -p "$derived/Build"
  printf '%s\n%s\napp-hosted-simulator-v1:%s\n' "$xcode_id" "$packages" "$simulator_arch" > "$stamp"
}
prepare_cached_products
start_simulator() {
  if [ -z "$simulator_id" ]; then
    local selection runtime simulator_type
    unit_step simulator-list 60 xcrun simctl list -j
    selection=$(python3 .github/scripts/select-simulator.py < "$validation_dir/simulator-list.log") || return 1
    runtime=${selection%%$'\n'*}
    simulator_type=${selection#*$'\n'}
    # Interrupted reuse must never recover a UUID from an earlier invocation.
    rm -f "$validation_dir/simulator-create.log"
    creating_simulator=1
    unit_step simulator-create 30 xcrun simctl create HotMic-player-ci "$simulator_type" "$runtime"
    read_created_simulator
    creating_simulator=0
  fi
  unit_step simulator-boot 30 xcrun simctl boot "$simulator_id" || true
}
# Complete generic compilation under its owned watchdog before the parent
# discovers/creates/boots the owned simulator. Xcode may do its own simulator
# discovery or bootstrap work during the generic build.
unit_step build-inputs 30 python3 .github/scripts/ci-unit-products.py prepare \
  --derived "$derived" --evidence "$validation_dir" --arch "$simulator_arch"
rm -f "$validation_dir/build-cancel"
rm -f "$validation_dir/simulator-build.json"
rm -rf "$validation_dir/UnitTests.xcresult"
python3 .github/scripts/ci-unit-command.py --name simulator-build \
  --log "$validation_dir/simulator-build.log" --seconds "$budget_simulator_build" \
  --total-deadline "$total_deadline" --reserve 35 --grace 5 \
  --cancel-file "$validation_dir/build-cancel" -- \
  xcodebuild build-for-testing \
  -project "$test_project" -scheme HotMicPlayerTests \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" \
  -only-testing:HotMicPlayerTests -showBuildTimingSummary \
  ARCHS="$simulator_arch" ONLY_ACTIVE_ARCH=YES "${speed_flags[@]}" &
build_watchdog_pid=$!
build_status=0
wait "$build_watchdog_pid" || build_status=$?
build_watchdog_pid=""
[ "$build_status" = 0 ] || exit "$build_status"
# Validate/capture the generated runner and all app resources before provisioning.
unit_step validate-products 30 python3 .github/scripts/ci-unit-products.py capture \
  --derived "$derived" --evidence "$validation_dir" --arch "$simulator_arch"
xctestrun=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["xctestrun"])' "$validation_dir/compiled-products.json")
start_simulator
# Await readiness after compilation: simctl boot alone may defer migration.
unit_step simulator 540 xcrun simctl bootstatus "$simulator_id" -b
# The iOS unit target includes native-player tests omitted by macOS swift test.
unit_step unit-tests "$budget_unit_tests" xcodebuild test-without-building \
  -xctestrun "$xctestrun" \
  -destination "platform=iOS Simulator,id=$simulator_id,arch=$simulator_arch" \
  -parallel-testing-enabled NO -only-testing:HotMicPlayerTests \
  -resultBundlePath "$validation_dir/UnitTests.xcresult"
enforce_total
