#!/bin/bash
# Simulator compiles of Sample and Examples. No tests and no simulator boot.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
source .github/scripts/ci-common.sh
validation_dir="${VALIDATION_DIR:-.bench/apps}"
mkdir -p "$validation_dir"
derived="$validation_dir/DerivedData"
started=$SECONDS
job_name=apps
budget_total=540
# The first app compiles the shared libraries; the later apps reuse DerivedData.
budget_sample=420
budget_example=240
build_app() {
  local project="$1" scheme="$2"
  xcodebuild build -project "$project" -scheme "$scheme" \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES "${speed_flags[@]}"
}
run_step Sample-simulator "$budget_sample" build_app Sample/HotMicPlayerDemo.xcodeproj HotMicPlayerDemo
run_step PlayerOnly-simulator "$budget_example" build_app Examples/PlayerOnly/PlayerOnly.xcodeproj PlayerOnly
run_step PlayerWithUI-simulator "$budget_example" build_app Examples/PlayerWithUI/PlayerWithUI.xcodeproj PlayerWithUI
run_step ReadyMadeOverlay-simulator "$budget_example" build_app Examples/ReadyMadeOverlay/ReadyMadeOverlay.xcodeproj ReadyMadeOverlay
run_step CustomOverlay-simulator "$budget_example" build_app Examples/CustomOverlay/CustomOverlay.xcodeproj CustomOverlay
run_step documentation-snippets 90 python3 .github/scripts/compile-doc-snippets.py --derived-data "$derived" --output "$validation_dir/snippets"
enforce_total
