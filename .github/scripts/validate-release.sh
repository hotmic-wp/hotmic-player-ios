#!/bin/bash
# Run from the repo root. BUILD_ONLY=1 defers the suite for local simulator smoke.
# One simulator build-for-testing produces the Sample scheme (libraries, demo, tests).
# One generic iOS build compiles the library products. Documentation and the public
# API inventory come from a single docbuild.
set -euo pipefail
validation_dir="${VALIDATION_DIR:-.bench/release}"
mkdir -p "$validation_dir"
derived="$validation_dir/DerivedData"
started=$SECONDS
# Budgets fail a badly regressed step before the 10-minute runner cancel.
# A cold macos-26 run of this pipeline sits well under these; the old per-product
# rebuilds and a second symbol-graph extract do not.
budget_partner_docs=60
budget_simulator=120
budget_simulator_build=300
budget_device=180
budget_docbuild=150
budget_drift=30
budget_unit_tests=240
simulator_id="${SIMULATOR_UDID:-}"
created_simulator=0
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
prepare_simulator() {
  simulator_id="${SIMULATOR_UDID:-}"
  if [ -n "$simulator_id" ]; then
    return 0
  fi
  # A CI-owned device avoids choosing an unrelated developer simulator.
  # Status checks stay explicit: this function runs inside `if`, which suppresses set -e.
  local selection runtime simulator_type
  selection=$(xcrun simctl list -j | python3 .github/scripts/select-simulator.py) || return 1
  runtime=${selection%%$'\n'*}
  simulator_type=${selection#*$'\n'}
  simulator_id=$(xcrun simctl create HotMic-player-ci "$simulator_type" "$runtime") || return 1
  created_simulator=1
  trap 'if [ "$created_simulator" = 1 ]; then xcrun simctl delete "$simulator_id"; fi' EXIT
  xcrun simctl boot "$simulator_id" || return 1
  xcrun simctl bootstatus "$simulator_id" -b || return 1
}
docbuild_and_api() {
  # arm64 only: the inventory reads that slice, and generic destinations otherwise
  # compile the x86_64 simulator again.
  xcodebuild docbuild -scheme HotMicPlayer-Package \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    OTHER_DOCC_FLAGS='--warnings-as-errors --analyze' CODE_SIGNING_ALLOWED=NO &&
  python3 bench/export_public_api.py \
    --derived-data "$derived" --output "$validation_dir/PUBLIC_API.md"
}
run_step partner-docs "$budget_partner_docs" bash .github/scripts/check-partner-docs.sh
if [ "${BUILD_ONLY:-0}" = 1 ]; then
  sim_destination='generic/platform=iOS Simulator'
else
  run_step simulator "$budget_simulator" prepare_simulator
  sim_destination="platform=iOS Simulator,id=$simulator_id"
fi
run_step simulator-build "$budget_simulator_build" xcodebuild build-for-testing \
  -project Sample/HotMicPlayerDemo.xcodeproj -scheme HotMicPlayerDemo \
  -destination "$sim_destination" -derivedDataPath "$derived" \
  CODE_SIGNING_ALLOWED=NO
if [ "${BUILD_ONLY:-0}" != 1 ]; then
  # The iOS unit target includes native-player tests omitted by macOS swift test.
  # UI benchmark/walkthrough tests are deliberately excluded from this short gate.
  # Run before the device and docbuild actions so they cannot replace these products.
  run_step unit-tests "$budget_unit_tests" xcodebuild test-without-building \
    -project Sample/HotMicPlayerDemo.xcodeproj -scheme HotMicPlayerDemo \
    -destination "$sim_destination" -derivedDataPath "$derived" \
    -parallel-testing-enabled NO -only-testing:HotMicPlayerTests \
    -resultBundlePath "$validation_dir/UnitTests.xcresult" CODE_SIGNING_ALLOWED=NO
fi
run_step device-libraries "$budget_device" xcodebuild build -scheme HotMicPlayer-Package \
  -destination 'generic/platform=iOS' -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO
run_step docbuild "$budget_docbuild" docbuild_and_api
run_step public-api-drift "$budget_drift" diff -u docs/PUBLIC_API.md "$validation_dir/PUBLIC_API.md"
echo "Release validation: $((SECONDS - started))s total"
