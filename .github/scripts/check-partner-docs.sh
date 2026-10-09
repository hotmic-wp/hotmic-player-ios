#!/bin/bash
# Reject private release coordination and machine-specific details in shipped docs.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
pattern='(^|[^[:alnum:]_])(worktree)([^[:alnum:]_]|$)|#[0-9]+|hem/|hem-[0-9]+|internal-tracker|/(Users|Volumes|home|tmp|private|var|mnt|root)/|(^|[^[:alnum:]_])[[:alpha:]]:[\\/]|[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}'
failed=0
while IFS= read -r -d '' file; do
  [ -f "$file" ] || continue
  if grep -n -i -I -E "$pattern" "$file"; then
    echo "Private or machine-specific content in $file" >&2
    failed=1
  else
    status=$?
    if [ "$status" -gt 1 ]; then exit "$status"; fi
  fi
done < <(git ls-files --cached --others --exclude-standard -z -- \
  docs README.md CHANGELOG.md ':(glob)**/*.docc/**')
if [ "$failed" = 1 ]; then exit 1; fi
echo 'Partner documentation content check passed.'
