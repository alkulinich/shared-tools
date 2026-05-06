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
# Polls every 100ms; returns 0 if the file appears within timeout_secs, 1 otherwise.
# Args: <path> <timeout_secs>
wait_for_file() {
  local path="$1"
  local timeout_secs="${2:-5}"
  local max_iters=$((timeout_secs * 10))
  local iters=0
  while [ ! -f "$path" ] && [ "$iters" -lt "$max_iters" ]; do
    sleep 0.1
    iters=$((iters + 1))
  done
  [ -f "$path" ]
}

# Wait until `jq -r <expr> <path>` returns <expected>, polling every 100ms.
# Used in place of wait_for_file when the file is overwritten asynchronously
# (the synchronous regex-only fallback exists immediately, but the subagent
# overwrite is what we actually want to assert against).
# Args: <path> <jq_expr> <expected> <timeout_secs>
wait_for_jq_value() {
  local path="$1"
  local jq_expr="$2"
  local expected="$3"
  local timeout_secs="${4:-5}"
  local max_iters=$((timeout_secs * 10))
  local iters=0 actual=""
  while [ "$iters" -lt "$max_iters" ]; do
    if [ -f "$path" ]; then
      actual=$(jq -r "$jq_expr" "$path" 2>/dev/null || echo "")
      [ "$actual" = "$expected" ] && return 0
    fi
    sleep 0.1
    iters=$((iters + 1))
  done
  return 1
}

# Read the integer byte-offset stored in <state_file>; echoes 0 if absent.
read_offset() {
  local state_file="$1"
  if [ -f "$state_file" ]; then
    cat "$state_file"
  else
    echo 0
  fi
}

# Count *.json files in a project's raw punt dir for a given session_id prefix.
# Args: <proj_dir> <session_id>
count_raw_files() {
  local proj="$1"
  local sid="$2"
  ls "$proj"/.claude/punts/raw/"$sid"-*.json 2>/dev/null | wc -l | tr -d ' '
}

# Echo the path to the (assumed unique) raw file for <session_id>, or empty.
find_raw_file() {
  local proj="$1"
  local sid="$2"
  ls "$proj"/.claude/punts/raw/"$sid"-*.json 2>/dev/null | head -n1
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
