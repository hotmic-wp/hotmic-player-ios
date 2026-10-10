#!/bin/bash
# Package tests only. Boot the simulator, then build, then test. Nothing overlaps.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
source .github/scripts/ci-common.sh
validation_dir="${VALIDATION_DIR:-.bench/unit}"
mkdir -p "$validation_dir"
derived="$validation_dir/DerivedData"
started=$SECONDS
job_name=unit-tests
# Cold macos-26 is about 2.5-3x this Mac. The compile cap is above the 323s miss.
budget_total=540
budget_simulator=180
budget_simulator_build=420
budget_unit_tests=240
simulator_id="${SIMULATOR_UDID:-}"
created_simulator=0
cleanup() {
  if [ "$created_simulator" = 1 ]; then
    xcrun simctl delete "$simulator_id" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
boot_simulator() {
  if [ -z "$simulator_id" ]; then
    local selection runtime simulator_type
    selection=$(xcrun simctl list -j | python3 .github/scripts/select-simulator.py) || return 1
    runtime=${selection%%$'\n'*}
    simulator_type=${selection#*$'\n'}
    simulator_id=$(xcrun simctl create HotMic-player-ci "$simulator_type" "$runtime") || return 1
    created_simulator=1
  fi
  xcrun simctl boot "$simulator_id" || true
  xcrun simctl bootstatus "$simulator_id" -b
}
run_step simulator "$budget_simulator" boot_simulator
run_step simulator-build "$budget_simulator_build" xcodebuild build-for-testing \
  -scheme HotMicPlayer-Package \
  -destination "platform=iOS Simulator,id=$simulator_id" -derivedDataPath "$derived" \
  -only-testing:HotMicPlayerTests \
  ONLY_ACTIVE_ARCH=YES "${speed_flags[@]}"
# The iOS unit target includes native-player tests omitted by macOS swift test.
run_step unit-tests "$budget_unit_tests" xcodebuild test-without-building \
  -scheme HotMicPlayer-Package \
  -destination "platform=iOS Simulator,id=$simulator_id" -derivedDataPath "$derived" \
  -parallel-testing-enabled NO -only-testing:HotMicPlayerTests \
  -resultBundlePath "$validation_dir/UnitTests.xcresult" \
  ONLY_ACTIVE_ARCH=YES "${speed_flags[@]}"
enforce_total
