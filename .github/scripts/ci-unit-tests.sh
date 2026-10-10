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
# Boot time varies on the runner, so that step has no budget of its own.
# The 540s total is what fails the job. The compile cap is above the 323s miss.
budget_total=540
budget_simulator_build=420
budget_unit_tests=240
# Drop restored products when the toolchain or package resolution changed.
# Source-only restores stay on disk so the compile is incremental.
package_fingerprint() {
  local files=(Package.swift) path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    files+=("$path")
  done <<EOF
$(find . -name Package.resolved -not -path './.git/*' -not -path './.bench/*' | sort)
EOF
  shasum -a 256 "${files[@]}" | shasum -a 256 | awk '{print $1}'
}
prepare_cached_products() {
  local xcode_id packages stamp old_xcode old_packages
  xcode_id=$(xcodebuild -version | awk 'END { print $NF }')
  packages=$(package_fingerprint)
  stamp="$derived/Build/.ci-stamp"
  if [ -f "$stamp" ]; then
    old_xcode=$(sed -n '1p' "$stamp")
    old_packages=$(sed -n '2p' "$stamp")
    if [ "$old_xcode" != "$xcode_id" ] || [ "$old_packages" != "$packages" ]; then
      echo "Removing cached build products from Xcode ${old_xcode} (${old_packages}); this run is Xcode ${xcode_id} (${packages})."
      rm -rf "$derived/Build" "$derived/ModuleCache.noindex" "$derived/SourcePackages"
    fi
  fi
  mkdir -p "$derived/Build"
  printf '%s\n%s\n' "$xcode_id" "$packages" > "$stamp"
}
prepare_cached_products
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
run_step simulator "" boot_simulator
run_step simulator-build "$budget_simulator_build" xcodebuild build-for-testing \
  -scheme HotMicPlayer-Package \
  -destination "platform=iOS Simulator,id=$simulator_id" -derivedDataPath "$derived" \
  -only-testing:HotMicPlayerTests \
  ONLY_ACTIVE_ARCH=YES "${speed_flags[@]}"
# The iOS unit target includes native-player tests omitted by macOS swift test.
rm -rf "$validation_dir/UnitTests.xcresult"
run_step unit-tests "$budget_unit_tests" xcodebuild test-without-building \
  -scheme HotMicPlayer-Package \
  -destination "platform=iOS Simulator,id=$simulator_id" -derivedDataPath "$derived" \
  -parallel-testing-enabled NO -only-testing:HotMicPlayerTests \
  -resultBundlePath "$validation_dir/UnitTests.xcresult" \
  ONLY_ACTIVE_ARCH=YES "${speed_flags[@]}"
enforce_total
