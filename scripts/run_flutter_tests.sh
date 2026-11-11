#!/usr/bin/env bash
# Multica-compatible runner built from the user's proven Hermes testing process.
# Usage: bash scripts/run_flutter_tests.sh [Flutter project directory]
# Results: 0 = every executed stage passed; 1 = at least one failure / required stage missing.
# Require integration tests for E2E tasks: QA_REQUIRE_INTEGRATION=1 bash ...
# Optional authorized user systemd scope: QA_USE_SYSTEMD_SCOPE=1 bash ...
# This script does not claim a skipped test is PASS.
set -uo pipefail

project="${1:-.}"
if ! cd -- "$project"; then echo "ERROR: project directory not found: $project" >&2; exit 1; fi
project="$(pwd -P)"
if [[ ! -f pubspec.yaml ]]; then echo "ERROR: not a Flutter project (missing pubspec.yaml): $project" >&2; exit 1; fi
if ! command -v flutter >/dev/null 2>&1; then echo 'ERROR: flutter not found in PATH' >&2; exit 1; fi

# Do not override the user's DISPLAY, WAYLAND_DISPLAY, XDG_RUNTIME_DIR, or SDK path.
# Multica's runtime may differ from the original Hermes session.
start="$(date +%s)"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
logroot="${QA_LOG_DIR:-$project/.qa-artifacts/qa-$stamp-$$}"
mkdir -p -- "$logroot" || { echo "ERROR: cannot create logs: $logroot" >&2; exit 1; }
summary="$logroot/results.tsv"
printf 'stage\tstatus\texit_code\n' > "$summary"
failed=0

mark() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" | tee -a "$summary"; }
run_stage() {
  local stage="$1" code
  shift
  printf '\n=== %s ===\n' "$stage"
  "$@" 2>&1 | tee "$logroot/$stage.log"
  code=${PIPESTATUS[0]}
  if [[ "$code" -eq 0 ]]; then mark "$stage" PASS 0
  else mark "$stage" FAIL "$code"; failed=1
  fi
}

run_stage analyze flutter analyze
if [[ -d test ]] && find test -type f -name '*.dart' -print -quit | grep -q .; then
  # Existing golden cases run here; do not update golden baselines automatically.
  run_stage flutter-test flutter test
else
  if [[ "${QA_REQUIRE_WIDGET_TESTS:-0}" == 1 ]]; then
    mark flutter-test FAIL missing-tests; failed=1
  else
    mark flutter-test NOT_RUN no-tests
  fi
fi

if [[ -d integration_test ]] && find integration_test -type f -name '*.dart' -print -quit | grep -q .; then
  if [[ "${QA_USE_SYSTEMD_SCOPE:-0}" == 1 ]]; then
    if ! command -v systemd-run >/dev/null 2>&1; then
      mark linux-integration FAIL systemd-run-not-found; failed=1
    else
      # Never embed an arbitrary project path inside shell source.
      # systemd-run is an opt-in, not a way to bypass disallowed resource limits.
      run_stage linux-integration systemd-run --user --scope --quiet -- \
        bash -c 'cd -- "$1" || exit 1; shift; exec "$@"' \
        qa-shell "$project" flutter test integration_test -d linux
    fi
  else
    run_stage linux-integration flutter test integration_test -d linux
  fi
else
  if [[ "${QA_REQUIRE_INTEGRATION:-0}" == 1 ]]; then
    mark linux-integration FAIL required-integration-test-missing; failed=1
  else
    mark linux-integration NOT_RUN no-integration-tests
  fi
fi

elapsed=$(( $(date +%s) - start ))
printf '\nRESULT=%s ELAPSED_SECONDS=%s LOG_DIR=%s\n' "$([[ "$failed" == 0 ]] && echo PASS || echo FAIL)" "$elapsed" "$logroot"
[[ "$failed" -eq 0 ]]
