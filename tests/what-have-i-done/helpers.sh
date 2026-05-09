#!/usr/bin/env bash
# Shared test helpers for tests/what-have-i-done/. Source from run-tests.sh.

TESTS_RUN=${TESTS_RUN:-0}
TESTS_FAILED=${TESTS_FAILED:-0}

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"
FIXTURES_DIR="$TESTS_DIR/fixtures"

assert_eq() {
  local expected="$1"
  local actual="$2"
  local msg="${3:-values not equal}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$expected" = "$actual" ]; then
    printf '  ok: %s\n' "$msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' \
      "$msg" "$expected" "$actual"
  fi
}

assert_contains() {
  local needle="$1"
  local haystack="$2"
  local msg="${3:-haystack should contain needle}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    printf '  ok: %s\n' "$msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n    needle:   %s\n    haystack:\n%s\n' \
      "$msg" "$needle" "$haystack"
  fi
}

assert_not_contains() {
  local needle="$1"
  local haystack="$2"
  local msg="${3:-haystack should NOT contain needle}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n    needle:   %s\n' "$msg" "$needle"
  else
    printf '  ok: %s\n' "$msg"
  fi
}

# Build a temp claude-projects-style root with controlled subdirs.
# Returns its path.
make_temp_projects_root() {
  mktemp -d -t whidtest.XXXXXX
}

# Add a Claude-projects-style subdir that holds <jsonl_first_line> as the
# first line of a session JSONL file. Args: <root> <subdir_name> <jsonl_line>
add_project_dir() {
  local root="$1"
  local name="$2"
  local first_line="$3"
  local sub="$root/$name"
  mkdir -p "$sub"
  printf '%s\n' "$first_line" > "$sub/session-1.jsonl"
}

# Touch every regular file under <root> with mtime "now" so the find -mtime -N
# filter sees them as recent.
touch_recent() {
  local root="$1"
  find "$root" -type f -exec touch {} + 2>/dev/null || true
  find "$root" -type d -exec touch {} + 2>/dev/null || true
}
