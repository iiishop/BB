#!/usr/bin/env bash
# Compatibility alias: the v3 script did NOT execute integration_test.
# Use run_flutter_tests.sh for all new QA checks.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
exec bash "$SCRIPT_DIR/run_flutter_tests.sh" "$@"
