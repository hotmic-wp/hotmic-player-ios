#!/bin/bash
# Reject private release coordination and machine-specific details in shipped docs.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
pattern='(^|[^[:alnum:]_])(worktree)([^[:alnum:]_]|$)|(^|[[:space:]])#[0-9]+([^[:alnum:]_]|$)|hem/|hem-[0-9]+|internal-tracker|/(Users|Volumes|home|tmp|private|var|mnt|root)/|(^|[^[:alnum:]_])[[:alpha:]]:[\\/]|[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}'
case_sensitive_pattern='(^|[^[:alnum:]_])PARTNER([^[:alnum:]_]|$)'
failed=0
while IFS= read -r -d '' file; do
  [ -f "$file" ] || continue
  for mode in insensitive sensitive; do
    flags=()
    selected_pattern="$case_sensitive_pattern"
    if [ "$mode" = insensitive ]; then flags=(-i); selected_pattern="$pattern"; fi
    # Allow this public tool name without hiding other matches on the same line.
    if sed 's/Swift Package Manager/SwiftPM/g' "$file" | grep -n -I -E "${flags[@]}" "$selected_pattern"; then
      echo "Private or machine-specific content in $file" >&2
      failed=1
    else
      status=$?
      if [ "$status" -gt 1 ]; then exit "$status"; fi
    fi
  done
done < <(git ls-files --cached --others --exclude-standard -z -- \
  docs README.md CHANGELOG.md ':(glob)**/*.docc/**')
if [ "$failed" = 1 ]; then exit 1; fi
echo 'Partner documentation content check passed.'
