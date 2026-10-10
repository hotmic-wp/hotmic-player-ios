# Sourced by the CI job scripts. Each job is a single runner; steps stay sequential.
speed_flags=(-skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO COMPILER_INDEX_STORE_ENABLE=NO ENABLE_PREVIEWS=NO)
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
    echo "::error::${name} took ${elapsed}s, over the ${budget}s budget. Failing before the 10-minute job timeout."
    exit 1
  fi
}
enforce_total() {
  local elapsed=$((SECONDS - started))
  echo "$job_name: ${elapsed}s total"
  if [ "$elapsed" -gt "$budget_total" ]; then
    echo "::error::${job_name} took ${elapsed}s, over the ${budget_total}s budget. Failing before the 10-minute job timeout cancels the run."
    exit 1
  fi
}
