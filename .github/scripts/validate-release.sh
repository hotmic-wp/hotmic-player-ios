#!/bin/bash
# Run from the repo root. BUILD_ONLY=1 defers the suite for local simulator smoke.
set -euo pipefail
validation_dir="${VALIDATION_DIR:-.bench/release}"
mkdir -p "$validation_dir"
derived="$validation_dir/DerivedData"
started=$SECONDS
run_step() {
  local name="$1"
  shift
  local began=$SECONDS
  echo "::group::$name"
  if ! "$@" > "$validation_dir/$name.log" 2>&1; then
    cat "$validation_dir/$name.log"
    return 1
  fi
  echo "$name: $((SECONDS - began))s"
  echo "::endgroup::"
}
run_step partner-docs bash .github/scripts/check-partner-docs.sh
# Shared DerivedData reuses the dependency-free package across every app.
run_step package xcodebuild build -scheme HotMicPlayer-Package \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO
for name in PlayerOnly PlayerWithUI; do
  for platform in 'iOS Simulator' iOS; do
    suffix=simulator
    if [ "$platform" = iOS ]; then suffix=device; fi
    run_step "$name-$suffix" xcodebuild build \
      -project "Examples/$name/$name.xcodeproj" -scheme "$name" \
      -destination "generic/platform=$platform" -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO
  done
done
for platform in 'iOS Simulator' iOS; do
  suffix=simulator
  if [ "$platform" = iOS ]; then suffix=device; fi
  run_step "Sample-$suffix" xcodebuild build \
    -project Sample/HotMicPlayerDemo.xcodeproj -scheme HotMicPlayerDemo \
    -destination "generic/platform=$platform" -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO
done
run_step docbuild xcodebuild docbuild -scheme HotMicPlayer-Package \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" \
  OTHER_DOCC_FLAGS='--warnings-as-errors --analyze' CODE_SIGNING_ALLOWED=NO
run_step public-docs python3 bench/export_public_api.py \
  --module-dir "$derived/Build/Products/Debug-iphonesimulator" \
  --graphs "$validation_dir/symbolgraphs" --output "$validation_dir/PUBLIC_API.md"
run_step public-api-drift diff -u docs/PUBLIC_API.md "$validation_dir/PUBLIC_API.md"
if [ "${BUILD_ONLY:-0}" != 1 ]; then
  simulator_id="${SIMULATOR_UDID:-}"
  created_simulator=0
  if [ -z "$simulator_id" ]; then
    # A CI-owned device avoids choosing an unrelated developer simulator.
    selection=$(xcrun simctl list -j | python3 .github/scripts/select-simulator.py)
    runtime=${selection%%$'\n'*}
    simulator_type=${selection#*$'\n'}
    simulator_id=$(xcrun simctl create HotMic-player-ci "$simulator_type" "$runtime")
    created_simulator=1
    trap 'if [ "$created_simulator" = 1 ]; then xcrun simctl delete "$simulator_id"; fi' EXIT
    xcrun simctl boot "$simulator_id"
    xcrun simctl bootstatus "$simulator_id" -b
  fi
  # The iOS unit target includes native-player tests omitted by macOS swift test.
  # UI benchmark/walkthrough tests are deliberately excluded from this short gate.
  run_step unit-tests xcodebuild test \
    -project Sample/HotMicPlayerDemo.xcodeproj -scheme HotMicPlayerDemo \
    -destination "platform=iOS Simulator,id=$simulator_id" -derivedDataPath "$derived" \
    -parallel-testing-enabled NO -only-testing:HotMicPlayerTests \
    -resultBundlePath "$validation_dir/UnitTests.xcresult" CODE_SIGNING_ALLOWED=NO
fi
echo "Release validation: $((SECONDS - started))s total"
