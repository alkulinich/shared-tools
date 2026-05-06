#!/usr/bin/env bash
# Test runner for the punts module. Sources helpers.sh and invokes each test_*
# function defined in tests/punts/test-*.sh. No external test framework needed.
set -uo pipefail

TESTS_RUN=0
TESTS_FAILED=0

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=helpers.sh
source "$DIR/helpers.sh"

# Source any test-*.sh files in this dir (each defines test_* functions).
for f in "$DIR"/test-*.sh; do
  [ -f "$f" ] || continue
  # shellcheck disable=SC1090
  source "$f"
done

# Run every shell function whose name starts with `test_`.
for fn in $(declare -F | awk '{print $3}' | grep '^test_' || true); do
  printf '%s\n' "$fn"
  "$fn"
done

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
