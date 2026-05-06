#!/usr/bin/env bash
# Shared test helpers for tests/punts/. Source from run-tests.sh.

# Test counters (set in run-tests.sh).
TESTS_RUN=${TESTS_RUN:-0}
TESTS_FAILED=${TESTS_FAILED:-0}

# Resolve paths relative to repo root.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"
FIXTURES_DIR="$TESTS_DIR/fixtures"

# Build a fresh temp "project" dir for each test. Returns its absolute path.
make_temp_project() {
  local tmp
  tmp="$(mktemp -d -t puntstest.XXXXXX)"
  mkdir -p "$tmp/.claude/punts"
  printf '%s\n' "$tmp"
}

# Build the Stop-hook stdin payload by templating fixtures/stdin-template.json.
# Args: <transcript_path> <session_id>
make_stdin() {
  local transcript_path="$1"
  local session_id="$2"
  jq -n \
    --arg tp "$transcript_path" \
    --arg sid "$session_id" \
    '{transcript_path: $tp, session_id: $sid}'
}

# Install a fake `claude` binary into <bin_dir> that, when invoked with -p,
# writes the contents of <fixture_path> to stdout and exits 0.
# Args: <bin_dir> <fixture_path>
install_fake_claude() {
  local bin_dir="$1"
  local fixture_path="$2"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/claude" <<EOF
#!/usr/bin/env bash
cat "$fixture_path"
EOF
  chmod +x "$bin_dir/claude"
}

# Wait for a file to exist (used because the subagent runs detached).
# Args: <path> <timeout_secs>
wait_for_file() {
  local path="$1"
  local timeout="${2:-5}"
  local elapsed=0
  while [ ! -f "$path" ] && [ "$elapsed" -lt "$timeout" ]; do
    sleep 0.1
    elapsed=$((elapsed + 1))
  done
  [ -f "$path" ]
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local msg="${3:-values not equal}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$expected" = "$actual" ]; then
    printf '  ok: %s\n' "$msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$msg" "$expected" "$actual"
  fi
}

assert_file_exists() {
  local path="$1"
  local msg="${2:-file should exist: $path}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ -f "$path" ]; then
    printf '  ok: %s\n' "$msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n' "$msg"
  fi
}

assert_file_absent() {
  local path="$1"
  local msg="${2:-file should not exist: $path}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ ! -f "$path" ]; then
    printf '  ok: %s\n' "$msg"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL: %s\n' "$msg"
  fi
}
