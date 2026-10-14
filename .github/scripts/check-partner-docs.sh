#!/bin/bash
# Reject machine-specific details and optionally supplied private terms in shipped content.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
pattern='(^|[^[:alnum:]_])worktree([^[:alnum:]_]|$)|(^|[[:space:]])#[0-9]+([^[:alnum:]_]|$)|hem/|/(Users|Volumes|home|tmp|private|var|mnt|root)/|(^|[^[:alnum:]_])[[:alpha:]]:[\\/]|[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}'
failed=0
while IFS= read -r -d '' file; do
  [ -f "$file" ] || continue
  if grep -I -i -E "$pattern" "$file" > /dev/null; then
    echo "Machine-specific or internal reference in $file" >&2
    failed=1
  else
    status=$?
    if [ "$status" -gt 1 ]; then exit "$status"; fi
  fi
  if [ -n "${PARTNER_DOCS_DENYLIST:-}" ]; then
    # Optional newline-separated literal terms; ignore empty lines and never print matched text.
    if grep -I -i -F -f <(printf '%s\n' "$PARTNER_DOCS_DENYLIST" | sed '/^[[:space:]]*$/d') "$file" > /dev/null; then
      echo "Configured private term found in $file" >&2
      failed=1
    else
      status=$?
      if [ "$status" -gt 1 ]; then exit "$status"; fi
    fi
  fi
done < <(git ls-files --cached --others --exclude-standard -z -- \
  docs Examples README.md CHANGELOG.md ':(glob)**/*.docc/**')
if [ "$failed" = 1 ]; then exit 1; fi
echo 'Partner documentation content check passed.'
