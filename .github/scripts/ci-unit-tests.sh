#!/bin/bash
# Package tests only. Build without a device, then boot and test. Nothing overlaps.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
source .github/scripts/ci-common.sh
validation_dir="${VALIDATION_DIR:-.bench/unit}"
mkdir -p "$validation_dir"
derived="$validation_dir/DerivedData"
started=$SECONDS
job_name=unit-tests
# Boot time varies on the runner, so that step has no budget of its own.
# The 540s total and 420s compile cap leave room within the ten-minute job.
budget_total=540
budget_simulator_build=420
budget_unit_tests=240
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
$(find . -name Package.resolved -not -path './.git/*' -not -path './.bench/*' | sort)
EOF
  shasum -a 256 "${files[@]}" | shasum -a 256 | awk '{print $1}'
}
prepare_cached_products() {
  local xcode_id packages stamp old_xcode old_packages old_build_mode
  xcode_id=$(xcodebuild -version | awk 'END { print $NF }')
  packages=$(package_fingerprint)
  stamp="$derived/Build/.ci-stamp"
  if [ -f "$stamp" ]; then
    old_xcode=$(sed -n '1p' "$stamp")
    old_packages=$(sed -n '2p' "$stamp")
    old_build_mode=$(sed -n '3p' "$stamp")
    if [ "$old_xcode" != "$xcode_id" ] || [ "$old_packages" != "$packages" ] || [ "$old_build_mode" != "generic-simulator-v1:$simulator_arch" ]; then
      echo "Removing cached products: toolchain, package resolution, or simulator build mode changed."
      rm -rf "$derived/Build" "$derived/ModuleCache.noindex" "$derived/SourcePackages"
    fi
  elif [ -d "$derived/Build" ]; then
    echo "Removing cached products without a compatibility stamp."
    rm -rf "$derived/Build" "$derived/ModuleCache.noindex" "$derived/SourcePackages"
  fi
  mkdir -p "$derived/Build"
  printf '%s\n%s\ngeneric-simulator-v1:%s\n' "$xcode_id" "$packages" "$simulator_arch" > "$stamp"
}
prepare_cached_products
simulator_id="${SIMULATOR_UDID:-}"
created_simulator=0
cleanup() {
  local status=$?
  if [ "$created_simulator" = 1 ]; then
    xcrun simctl shutdown "$simulator_id" >/dev/null 2>&1 || true
    if ! xcrun simctl delete "$simulator_id"; then
      echo "::error::Could not delete owned simulator $simulator_id."
      [ "$status" != 0 ] || status=1
    fi
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
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
# A generic destination does not need a booted device or device discovery during
# compilation. Explicit ARCHS keeps generic builds to the same native slice used
# by test-without-building, including Intel hosts.
run_step simulator-build "$budget_simulator_build" xcodebuild build-for-testing \
  -scheme HotMicPlayer-Package \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" \
  -only-testing:HotMicPlayerTests -showBuildTimingSummary \
  ARCHS="$simulator_arch" ONLY_ACTIVE_ARCH=YES "${speed_flags[@]}"
run_step simulator "" boot_simulator
# The iOS unit target includes native-player tests omitted by macOS swift test.
rm -rf "$validation_dir/UnitTests.xcresult"
run_step unit-tests "$budget_unit_tests" xcodebuild test-without-building \
  -scheme HotMicPlayer-Package \
  -destination "platform=iOS Simulator,id=$simulator_id,arch=$simulator_arch" -derivedDataPath "$derived" \
  -parallel-testing-enabled NO -only-testing:HotMicPlayerTests \
  -resultBundlePath "$validation_dir/UnitTests.xcresult" \
  ARCHS="$simulator_arch" ONLY_ACTIVE_ARCH=YES "${speed_flags[@]}"
enforce_total
