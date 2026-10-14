#!/bin/bash
# Partner docs, one device library compile, then DocC and the API inventory.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
source .github/scripts/ci-common.sh
validation_dir="${VALIDATION_DIR:-.bench/checks}"
mkdir -p "$validation_dir"
derived="$validation_dir/DerivedData"
started=$SECONDS
job_name=checks
budget_total=540
budget_partner_docs=60
budget_device=240
budget_docbuild=240
budget_drift=30
docbuild_and_api() {
  xcodebuild docbuild -scheme HotMicPlayer-Package \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES "${speed_flags[@]}" \
    OTHER_DOCC_FLAGS='--warnings-as-errors --analyze' &&
  python3 .github/scripts/export_public_api.py \
    --derived-data "$derived" --output "$validation_dir/PUBLIC_API.md"
}
run_step partner-docs "$budget_partner_docs" bash .github/scripts/check-partner-docs.sh
run_step device-libraries "$budget_device" xcodebuild build -scheme HotMicPlayer-Package \
  -destination 'generic/platform=iOS' -derivedDataPath "$derived" \
  ARCHS=arm64 "${speed_flags[@]}"
run_step docbuild "$budget_docbuild" docbuild_and_api
run_step public-api-drift "$budget_drift" diff -u docs/PUBLIC_API.md "$validation_dir/PUBLIC_API.md"
enforce_total
