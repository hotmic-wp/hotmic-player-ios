#!/bin/bash
# The API inventory must come from the pinned toolchain on every runner.
set -euo pipefail
if [[ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
  echo "::error::Xcode 26.6 is required but is missing at $DEVELOPER_DIR. Install it on the runner before running the API drift check."
  exit 1
fi
version=$(xcodebuild -version)
if [[ "${version%%$'\n'*}" != 'Xcode 26.6' ]]; then
  echo "::error::Expected Xcode 26.6 at $DEVELOPER_DIR; found $version. The API inventory must use the pinned toolchain."
  exit 1
fi
printf '%s\n' "$version"
