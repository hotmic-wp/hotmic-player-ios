#!/bin/bash
# Run from the repo root. BUILD_ONLY=1 defers the suite for local simulator smoke.
# The simulator boots while the test build compiles. Device and DocC builds use
# their own DerivedData and run while the unit tests execute.
set -euo pipefail
validation_dir="${VALIDATION_DIR:-.bench/release}"
mkdir -p "$validation_dir"
derived="$validation_dir/DerivedData"
device_derived="$validation_dir/device-derived"
docs_derived="$validation_dir/docs-derived"
started=$SECONDS
# Own-step budgets. Overlapped work can be slower than the wall clock; a hung
# boot or a returned multi-minute extract still fails here.
budget_partner_docs=60
budget_simulator=180
budget_simulator_build=300
budget_device=180
budget_docbuild=150
budget_drift=30
budget_unit_tests=240
simulator_id="${SIMULATOR_UDID:-}"
created_simulator=0
bg_pids=()
# Cold runners spend real time writing the index store and validating an empty
# plugin list. Signing is unused for these generic and simulator builds.
speed_flags=(-skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO COMPILER_INDEX_STORE_ENABLE=NO ENABLE_PREVIEWS=NO)
cleanup() {
  local pid
  if [ "${#bg_pids[@]}" -gt 0 ]; then
    for pid in "${bg_pids[@]}"; do
      kill "$pid" 2>/dev/null || true
    done
    for pid in "${bg_pids[@]}"; do
      wait "$pid" 2>/dev/null || true
    done
  fi
  if [ "$created_simulator" = 1 ]; then
    xcrun simctl delete "$simulator_id" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
run_step() {
  local name="$1" budget="$2"
  shift 2
  local began=$SECONDS
  echo "::group::$name"
  if ! "$@" > "$validation_dir/$name.log" 2>&1; then
    cat "$validation_dir/$name.log"
    echo "::endgroup::"
    return 1
  fi
  local elapsed=$((SECONDS - began))
  echo "$name: ${elapsed}s"
  echo "::endgroup::"
  if [ "$elapsed" -gt "$budget" ]; then
    echo "::error::${name} took ${elapsed}s, over the ${budget}s budget. This step regressed enough to miss the 10-minute PR check."
    exit 1
  fi
}
start_logged() {
  local name="$1"
  shift
  local began
  began=$(date +%s)
  (
    status=0
    "$@" > "$validation_dir/$name.log" 2>&1 || status=$?
    echo $(( $(date +%s) - began )) > "$validation_dir/$name.seconds"
    exit "$status"
  ) &
  last_bg_pid=$!
  bg_pids+=("$last_bg_pid")
}
finish_logged() {
  local name="$1" budget="$2" pid="$3" status=0 elapsed
  wait "$pid" || status=$?
  elapsed=$(cat "$validation_dir/$name.seconds")
  echo "::group::$name"
  if [ "$status" != 0 ]; then
    cat "$validation_dir/$name.log"
    echo "::endgroup::"
    return 1
  fi
  echo "$name: ${elapsed}s (overlapped)"
  echo "::endgroup::"
  if [ "$elapsed" -gt "$budget" ]; then
    echo "::error::${name} took ${elapsed}s, over the ${budget}s budget. This step regressed enough to miss the 10-minute PR check."
    exit 1
  fi
}
create_simulator() {
  if [ -n "$simulator_id" ]; then
    return 0
  fi
  # A CI-owned device avoids choosing an unrelated developer simulator.
  local selection runtime simulator_type
  selection=$(xcrun simctl list -j | python3 .github/scripts/select-simulator.py) || return 1
  runtime=${selection%%$'\n'*}
  simulator_type=${selection#*$'\n'}
  simulator_id=$(xcrun simctl create HotMic-player-ci "$simulator_type" "$runtime") || return 1
  created_simulator=1
}
boot_simulator() {
  # xcodebuild may boot the same device. Ignore the already-booting error and wait.
  xcrun simctl boot "$simulator_id" || true
  xcrun simctl bootstatus "$simulator_id" -b
}
device_libraries() {
  xcodebuild build -scheme HotMicPlayer-Package \
    -destination 'generic/platform=iOS' -derivedDataPath "$device_derived" \
    ARCHS=arm64 "${speed_flags[@]}"
}
docbuild_and_api() {
  # arm64 only: the inventory reads that slice, and a generic simulator
  # destination otherwise compiles x86_64 as well.
  xcodebuild docbuild -scheme HotMicPlayer-Package \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$docs_derived" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES "${speed_flags[@]}" \
    OTHER_DOCC_FLAGS='--warnings-as-errors --analyze' &&
  python3 bench/export_public_api.py \
    --derived-data "$docs_derived" --output "$validation_dir/PUBLIC_API.md"
}
run_step partner-docs "$budget_partner_docs" bash .github/scripts/check-partner-docs.sh
if [ "${BUILD_ONLY:-0}" = 1 ]; then
  sim_destination='generic/platform=iOS Simulator'
else
  create_simulator
  echo "Booting the simulator while the test build compiles."
  start_logged simulator boot_simulator
  boot_pid=$last_bg_pid
  sim_destination="platform=iOS Simulator,id=$simulator_id"
fi
run_step simulator-build "$budget_simulator_build" xcodebuild build-for-testing \
  -project Sample/HotMicPlayerDemo.xcodeproj -scheme HotMicPlayerDemo \
  -destination "$sim_destination" -derivedDataPath "$derived" \
  -only-testing:HotMicPlayerTests \
  ONLY_ACTIVE_ARCH=YES "${speed_flags[@]}"
if [ "${BUILD_ONLY:-0}" != 1 ]; then
  echo "Compiling device libraries and documentation while the unit tests run."
  start_logged device-libraries device_libraries
  device_pid=$last_bg_pid
  start_logged docbuild docbuild_and_api
  doc_pid=$last_bg_pid
  finish_logged simulator "$budget_simulator" "$boot_pid"
  # The iOS unit target includes native-player tests omitted by macOS swift test.
  # UI benchmark/walkthrough tests are deliberately excluded from this short gate.
  run_step unit-tests "$budget_unit_tests" xcodebuild test-without-building \
    -project Sample/HotMicPlayerDemo.xcodeproj -scheme HotMicPlayerDemo \
    -destination "$sim_destination" -derivedDataPath "$derived" \
    -parallel-testing-enabled NO -only-testing:HotMicPlayerTests \
    -resultBundlePath "$validation_dir/UnitTests.xcresult" \
    ONLY_ACTIVE_ARCH=YES "${speed_flags[@]}"
  finish_logged device-libraries "$budget_device" "$device_pid"
  finish_logged docbuild "$budget_docbuild" "$doc_pid"
else
  echo "Compiling device libraries and documentation together."
  start_logged device-libraries device_libraries
  device_pid=$last_bg_pid
  start_logged docbuild docbuild_and_api
  doc_pid=$last_bg_pid
  finish_logged device-libraries "$budget_device" "$device_pid"
  finish_logged docbuild "$budget_docbuild" "$doc_pid"
fi
run_step public-api-drift "$budget_drift" diff -u docs/PUBLIC_API.md "$validation_dir/PUBLIC_API.md"
echo "Release validation: $((SECONDS - started))s total"
