# Punt Detection & Triage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture session-end "pre-existing" / out-of-scope findings as structured evidence and gate promotion to curated knowledge behind a single human-triage step.

**Architecture:** Stop hook regex-screens the transcript for either an explicit `[PUNT]:` marker or soft phrasing, then forks a backgrounded `claude -p` subagent to extract structured evidence into `.claude/punts/raw/<session>.json`. Triage runs on demand via `/rulez:punts-triage`, promoting approved entries to git-tracked `.claude/punts/<slug>.md` files. Falls back to raw regex hits when `claude` is not on PATH.

**Tech Stack:** Bash 3.2+ (macOS default), `jq`, Claude Code Stop hook protocol, headless `claude -p`.

**Repo conventions to follow:**
- Scripts in `scripts/` use `#!/usr/bin/env bash` + `set -euo pipefail` + `SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"`.
- Slash commands live in `commands/rulez/<name>.md` and become `/rulez:<name>`.
- Settings template `settings.json` is merged into `~/.claude/settings.json` by `bin/setup` (additive permissions; `statusLine` and `hooks` are NOT replaced if already present).
- Commits use `git commit -F /tmp/<msg>.txt` because heredoc-quoted markdown trips bash on this repo (handoffs document this twice).
- Two-commit release pattern: a `feat:`/`fix:` for behavior change, then `chore: release vX.Y.Z` for `VERSION` + `UPGRADE.md`.

**Spec:** `docs/superpowers/specs/2026-05-06-punt-detection-design.md` (commit `9345658`).

---

## File Structure

**New files:**
- `scripts/punts-detect.sh` — Stop hook entry point. Regex-screens transcript, forks subagent, writes raw evidence.
- `scripts/punts-extract-prompt.sh` — Builds the prompt fed to `claude -p`. Pure stdout, no side effects.
- `commands/rulez/punts-triage.md` — `/rulez:punts-triage` slash command. Markdown skill instructing Claude to walk raw evidence interactively.
- `tests/punts/run-tests.sh` — Test runner (entry point). Sources helpers, calls each `test_*` function, reports pass/fail count.
- `tests/punts/helpers.sh` — Shared assertions (`assert_eq`, `assert_file_exists`, `wait_for_file`), temp-project setup, fake-`claude`-binary scaffolding.
- `tests/punts/fixtures/transcript-clean.jsonl` — Assistant message with no punt phrases.
- `tests/punts/fixtures/transcript-soft-phrase.jsonl` — Assistant message containing "pre-existing" phrasing.
- `tests/punts/fixtures/transcript-marker.jsonl` — Assistant message containing `[PUNT]: <reason>`.
- `tests/punts/fixtures/stdin-template.json` — Template Stop-hook stdin payload (`transcript_path` and `session_id` substituted at test time).

**Modified files:**
- `RULEZ.md` — append `## Punts` section with the soft `[PUNT]:` marker convention.
- `settings.json` — add Stop hook entry to `hooks` object; add new bash permissions to `permissions.allow`; add `Skill(rulez:punts-triage)`.
- `bin/setup` — extend the conservative-merge logic to handle the new Stop hook (skip if a rulez-claudeset Stop hook is already present).
- `VERSION` — `1.1.4` → `1.2.0`.
- `UPGRADE.md` — new `## To v1.2.0 — from v1.1.4` section at the top.

**No change to:** `.gitignore` (project root already ignores `.claude/`), `CLAUDE.md`, existing scripts/commands.

---

## Task 1: Test scaffolding for punts module

**Files:**
- Create: `tests/punts/run-tests.sh`
- Create: `tests/punts/helpers.sh`

- [ ] **Step 1: Write `tests/punts/helpers.sh`**

```bash
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
```

- [ ] **Step 2: Write `tests/punts/run-tests.sh`**

```bash
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
```

- [ ] **Step 3: Make both scripts executable**

```bash
chmod +x tests/punts/run-tests.sh tests/punts/helpers.sh
```

- [ ] **Step 4: Verify the runner exits 0 with no tests defined**

Run: `bash tests/punts/run-tests.sh`
Expected: `0 tests run, 0 failed` and exit code 0.

- [ ] **Step 5: Commit**

```bash
printf 'test: scaffold punts test runner\n\nMinimal bash test framework with mktemp-based project isolation,\nfake claude binary support, and standard assertion helpers. No tests\nyet — runner exits clean.\n\nCo-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>\n' > /tmp/cc-msg-task1.txt
git add tests/punts/run-tests.sh tests/punts/helpers.sh
git commit -F /tmp/cc-msg-task1.txt
```

---

## Task 2: Clean transcript path (no hits → exit 0, no file)

**Files:**
- Create: `tests/punts/fixtures/transcript-clean.jsonl`
- Create: `tests/punts/fixtures/stdin-template.json` (unused directly; documented for future tasks)
- Create: `tests/punts/test-detect.sh`
- Create: `scripts/punts-detect.sh`

- [ ] **Step 1: Write the clean transcript fixture**

`tests/punts/fixtures/transcript-clean.jsonl`:
```
{"type":"user","message":{"content":"add a feature"}}
{"type":"assistant","message":{"content":"Done. The implementation passes all tests."}}
```

(Two lines, ending with newline. Each line is a single JSON object — JSONL format Claude Code uses for transcripts.)

- [ ] **Step 2: Write the failing test**

Create `tests/punts/test-detect.sh`:
```bash
#!/usr/bin/env bash
# Tests for scripts/punts-detect.sh.

test_clean_transcript_writes_no_file() {
  local proj transcript stdin out
  proj="$(make_temp_project)"
  transcript="$FIXTURES_DIR/transcript-clean.jsonl"
  stdin="$(make_stdin "$transcript" "session-clean-001")"
  out="$proj/.claude/punts/raw/session-clean-001.json"

  ( cd "$proj" && printf '%s' "$stdin" | bash "$SCRIPTS_DIR/punts-detect.sh" )

  assert_file_absent "$out" "clean transcript: no raw JSON written"
  rm -rf "$proj"
}
```

- [ ] **Step 3: Run the test, expect failure (script does not exist)**

Run: `bash tests/punts/run-tests.sh`
Expected: a `bash: ... punts-detect.sh: No such file or directory` error and `1 tests run, 1 failed` — actually since the test runs the missing script in a subshell, the assertion still runs. The file does not exist regardless, so the assertion may pass spuriously. To be safe, the failure mode here is the missing script error message in the output.

To make TDD discipline tighter, run only the script directly first to confirm absence:
```bash
ls scripts/punts-detect.sh 2>&1 | head -1
```
Expected: `ls: scripts/punts-detect.sh: No such file or directory`.

- [ ] **Step 4: Implement the minimal script (clean-case only)**

Create `scripts/punts-detect.sh`:
```bash
#!/usr/bin/env bash
# Stop hook for Claude Code sessions. When the assistant declines to fix an
# issue (calling it pre-existing, out of scope, etc., or marking it [PUNT]:),
# capture evidence to .claude/punts/raw/<session>.json for later triage.
#
# Inputs (stdin JSON):
#   .transcript_path  Absolute path to the session's JSONL transcript.
#   .session_id       Stable UUID identifying the session.
#
# Outputs:
#   .claude/punts/raw/<session_id>.json (only when at least one regex hit found)
#
# Behavior:
#   1. Regex-screen the transcript for [PUNT]: marker or soft phrasing.
#   2. If no hits, exit 0 silently.
#   3. If hits and `claude` is on PATH, fork a backgrounded `claude -p` to
#      extract structured evidence.
#   4. If hits and `claude` is not on PATH, write the raw regex hits as a
#      fallback so evidence is never lost.
#
# See docs/superpowers/specs/2026-05-06-punt-detection-design.md.
set -euo pipefail

input=$(cat)
transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')
session_id=$(echo "$input" | jq -r '.session_id // empty')

# Bail if transcript is missing (Stop can fire before flush).
[ -z "$transcript_path" ] && exit 0
[ ! -f "$transcript_path" ] && exit 0

# Regex screen — placeholder, to be filled in Task 3.
exit 0
```

- [ ] **Step 5: Make it executable**

```bash
chmod +x scripts/punts-detect.sh
```

- [ ] **Step 6: Run the test, expect pass**

Run: `bash tests/punts/run-tests.sh`
Expected: `1 tests run, 0 failed` and exit code 0.

- [ ] **Step 7: Commit**

```bash
printf 'feat: punts-detect.sh — clean-transcript path\n\nMinimal Stop hook that reads stdin JSON, validates transcript_path,\nand exits 0 silently when there is nothing to capture. Detection\nlogic comes in subsequent commits.\n\nCo-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>\n' > /tmp/cc-msg-task2.txt
git add scripts/punts-detect.sh tests/punts/test-detect.sh tests/punts/fixtures/transcript-clean.jsonl
git commit -F /tmp/cc-msg-task2.txt
```

---

## Task 3: Soft-phrase detection with regex-fallback write

**Files:**
- Create: `tests/punts/fixtures/transcript-soft-phrase.jsonl`
- Modify: `tests/punts/test-detect.sh` (add new test function)
- Modify: `scripts/punts-detect.sh:end`

- [ ] **Step 1: Write the soft-phrase fixture**

`tests/punts/fixtures/transcript-soft-phrase.jsonl`:
```
{"type":"user","message":{"content":"refactor the parser"}}
{"type":"assistant","message":{"content":"Done. I noticed the auth middleware has a pre-existing bug — leaving it for later since it is unrelated to this change."}}
```

- [ ] **Step 2: Append the failing test to `tests/punts/test-detect.sh`**

```bash
test_soft_phrase_writes_fallback() {
  local proj transcript stdin out
  proj="$(make_temp_project)"
  transcript="$FIXTURES_DIR/transcript-soft-phrase.jsonl"
  stdin="$(make_stdin "$transcript" "session-soft-001")"
  out="$proj/.claude/punts/raw/session-soft-001.json"

  # Override PATH so claude binary is not found — exercises fallback path.
  ( cd "$proj" && PATH="/usr/bin:/bin" printf '%s' "$stdin" | bash "$SCRIPTS_DIR/punts-detect.sh" )

  assert_file_exists "$out" "soft-phrase: regex fallback JSON written"
  if [ -f "$out" ]; then
    local fallback hits
    fallback=$(jq -r '.fallback // empty' "$out")
    assert_eq "regex-only" "$fallback" "soft-phrase: fallback field is regex-only"
    hits=$(jq -r '.regex_hits // empty' "$out")
    case "$hits" in
      *pre-existing*) printf '  ok: soft-phrase: regex_hits contains pre-existing\n'; TESTS_RUN=$((TESTS_RUN + 1)) ;;
      *) printf '  FAIL: soft-phrase: regex_hits missing pre-existing\n'; TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)) ;;
    esac
  fi
  rm -rf "$proj"
}
```

- [ ] **Step 3: Run the test, expect failure**

Run: `bash tests/punts/run-tests.sh`
Expected: `2 tests run, 1 failed` (the new test fails because no file is written yet).

- [ ] **Step 4: Replace the placeholder in `scripts/punts-detect.sh`**

Replace the line `# Regex screen — placeholder, to be filled in Task 3.` and the trailing `exit 0` with:

```bash
# Regex screen for soft phrases that signal a punt. Case-insensitive.
PUNT_PHRASES='pre-existing|pre existing|already broken|out of scope|not related to (this|the change)|unrelated to (this|the change)|existing (issue|bug)|leave (this|that|it) for later|leaving (this|that) (for now|alone)|outside (the|this) scope'

# Look only at assistant messages — user input is irrelevant for punt detection.
hits=$(jq -c 'select(.type=="assistant") | .message.content // empty' "$transcript_path" 2>/dev/null \
  | grep -iE "$PUNT_PHRASES" || true)

# No hits → nothing to capture.
[ -z "$hits" ] && exit 0

# Ensure the project punts directory exists (cwd is project root for Stop hooks).
mkdir -p .claude/punts/raw

out=".claude/punts/raw/${session_id}.json"

# Subagent path comes in Task 5. For now, always write the regex-only fallback.
jq -n --arg hits "$hits" '{regex_hits: $hits, fallback: "regex-only"}' > "$out.tmp"
mv "$out.tmp" "$out"
exit 0
```

- [ ] **Step 5: Run the test, expect pass**

Run: `bash tests/punts/run-tests.sh`
Expected: `4 tests run, 0 failed` (the soft-phrase test adds 3 assertions: file exists, fallback field, hits content).

- [ ] **Step 6: Commit**

```bash
printf 'feat: detect soft-phrase punts and write regex fallback JSON\n\nWhen the assistant transcript contains pre-existing / out-of-scope /\nunrelated-to-this-change phrasing, write evidence to\n.claude/punts/raw/<session>.json. Subagent path comes next; for now\nthe output is the raw regex-hit lines so evidence is never lost when\nclaude -p is unavailable.\n\nCo-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>\n' > /tmp/cc-msg-task3.txt
git add scripts/punts-detect.sh tests/punts/test-detect.sh tests/punts/fixtures/transcript-soft-phrase.jsonl
git commit -F /tmp/cc-msg-task3.txt
```

---

## Task 4: `[PUNT]:` marker detection

**Files:**
- Create: `tests/punts/fixtures/transcript-marker.jsonl`
- Modify: `tests/punts/test-detect.sh` (add new test function)
- Modify: `scripts/punts-detect.sh` (extend regex to include marker)

- [ ] **Step 1: Write the marker fixture**

`tests/punts/fixtures/transcript-marker.jsonl`:
```
{"type":"user","message":{"content":"fix the parser"}}
{"type":"assistant","message":{"content":"Done with the parser. [PUNT]: noticed the auth middleware double-validates session tokens at src/auth/middleware.ts:42, leaving for a follow-up."}}
```

- [ ] **Step 2: Append the failing test**

To `tests/punts/test-detect.sh`:
```bash
test_marker_detected() {
  local proj transcript stdin out
  proj="$(make_temp_project)"
  transcript="$FIXTURES_DIR/transcript-marker.jsonl"
  stdin="$(make_stdin "$transcript" "session-marker-001")"
  out="$proj/.claude/punts/raw/session-marker-001.json"

  ( cd "$proj" && PATH="/usr/bin:/bin" printf '%s' "$stdin" | bash "$SCRIPTS_DIR/punts-detect.sh" )

  assert_file_exists "$out" "marker: regex fallback JSON written"
  if [ -f "$out" ]; then
    local hits
    hits=$(jq -r '.regex_hits // empty' "$out")
    case "$hits" in
      *'[PUNT]:'*) printf '  ok: marker: regex_hits contains [PUNT]:\n'; TESTS_RUN=$((TESTS_RUN + 1)) ;;
      *) printf '  FAIL: marker: regex_hits missing [PUNT]:\n'; TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)) ;;
    esac
  fi
  rm -rf "$proj"
}
```

- [ ] **Step 3: Run the test, expect failure**

Run: `bash tests/punts/run-tests.sh`
Expected: the marker test fails — the soft-phrase regex does not match `[PUNT]:` lines, so the script exits 0 without writing.

- [ ] **Step 4: Extend the regex in `scripts/punts-detect.sh`**

Replace the `PUNT_PHRASES=` line with:
```bash
PUNT_PHRASES='\[PUNT\]:|pre-existing|pre existing|already broken|out of scope|not related to (this|the change)|unrelated to (this|the change)|existing (issue|bug)|leave (this|that|it) for later|leaving (this|that) (for now|alone)|outside (the|this) scope'
```

(Add `\[PUNT\]:|` at the front. The regex is alternation so order does not matter for matching, but putting the explicit marker first makes intent clear when reading.)

- [ ] **Step 5: Run the test, expect pass**

Run: `bash tests/punts/run-tests.sh`
Expected: all tests pass; counter shows `6 tests run, 0 failed`.

- [ ] **Step 6: Commit**

```bash
printf 'feat: also detect explicit [PUNT]: marker lines\n\nBelt-and-suspenders signal: if the assistant explicitly tags an\nout-of-scope decision as [PUNT]: <reason>, surface it the same way\nas the soft-phrase hits. The marker convention itself is documented\nin RULEZ.md in a later commit.\n\nCo-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>\n' > /tmp/cc-msg-task4.txt
git add scripts/punts-detect.sh tests/punts/test-detect.sh tests/punts/fixtures/transcript-marker.jsonl
git commit -F /tmp/cc-msg-task4.txt
```

---

## Task 5: Fork `claude -p` subagent when available, write structured JSON

**Files:**
- Modify: `tests/punts/helpers.sh` (already has `install_fake_claude` and `wait_for_file` — verify)
- Modify: `tests/punts/test-detect.sh` (add new test using fake claude)
- Modify: `scripts/punts-detect.sh` (replace fallback-only with subagent-fork-with-fallback)

- [ ] **Step 1: Append the failing test**

To `tests/punts/test-detect.sh`:
```bash
test_subagent_writes_structured_json() {
  local proj transcript stdin out fake_bin fake_payload
  proj="$(make_temp_project)"
  transcript="$FIXTURES_DIR/transcript-soft-phrase.jsonl"
  stdin="$(make_stdin "$transcript" "session-subagent-001")"
  out="$proj/.claude/punts/raw/session-subagent-001.json"

  # Fake claude binary that emits a structured evidence array (one row).
  fake_bin="$proj/bin"
  fake_payload="$proj/fake-claude-output.json"
  cat > "$fake_payload" <<'EOF'
[
  {
    "id": "0000000000000000000000000000000000000001",
    "session_id": "session-subagent-001",
    "session_ended_at": "2026-05-06T14:30:00Z",
    "branch": "main",
    "evidence_quote": "the auth middleware has a pre-existing bug — leaving it",
    "context_quote": "...",
    "claim": "auth middleware bug",
    "files_mentioned": [],
    "regex_hit": "pre-existing",
    "source": "regex",
    "subagent_confidence": "medium"
  }
]
EOF
  install_fake_claude "$fake_bin" "$fake_payload"

  ( cd "$proj" && PATH="$fake_bin:$PATH" printf '%s' "$stdin" | bash "$SCRIPTS_DIR/punts-detect.sh" )

  # Subagent runs detached — wait up to 5s for the output file to appear.
  if wait_for_file "$out" 5; then
    printf '  ok: subagent: output file appeared within timeout\n'
    TESTS_RUN=$((TESTS_RUN + 1))
  else
    printf '  FAIL: subagent: output file did not appear within 5s\n'
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    rm -rf "$proj"
    return
  fi

  local first_id
  first_id=$(jq -r '.[0].id // empty' "$out")
  assert_eq "0000000000000000000000000000000000000001" "$first_id" \
    "subagent: structured JSON id passed through"
  rm -rf "$proj"
}
```

- [ ] **Step 2: Run the test, expect failure**

Run: `bash tests/punts/run-tests.sh`
Expected: the subagent test fails — `punts-detect.sh` currently always writes the regex fallback, never invokes claude. The output JSON will be the fallback shape, not an array, so `jq -r '.[0].id'` returns `null` and the assertion mismatches.

- [ ] **Step 3: Replace the bottom of `scripts/punts-detect.sh`**

Replace the block starting at `mkdir -p .claude/punts/raw` to end of file with:

```bash
# Ensure the project punts directory exists (cwd is project root for Stop hooks).
mkdir -p .claude/punts/raw

out=".claude/punts/raw/${session_id}.json"

# Resolve claude binary location. If unavailable, fall through to regex-only
# fallback so evidence is never lost.
CLAUDE_BIN="$(command -v claude || true)"

if [ -n "$CLAUDE_BIN" ]; then
  # Subagent path — extract structured evidence in the background.
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  prompt="$(bash "$SCRIPT_DIR/punts-extract-prompt.sh" "$transcript_path" "$session_id" "$hits")"
  (
    "$CLAUDE_BIN" -p "$prompt" --output-format json --max-turns 1 \
      > "$out.tmp" 2>/dev/null \
    && mv "$out.tmp" "$out" \
    || jq -n --arg hits "$hits" '{regex_hits: $hits, fallback: "subagent-failed"}' > "$out"
  ) &
  disown
else
  # No claude binary — write regex hits as a fallback.
  jq -n --arg hits "$hits" '{regex_hits: $hits, fallback: "regex-only"}' > "$out.tmp"
  mv "$out.tmp" "$out"
fi
exit 0
```

NOTE: this references `scripts/punts-extract-prompt.sh` which does not exist yet. Task 6 creates it. To keep this task green in isolation, also create a stub now.

- [ ] **Step 4: Create stub `scripts/punts-extract-prompt.sh`**

```bash
#!/usr/bin/env bash
# Stub. Real prompt builder lands in Task 6.
# Args: <transcript_path> <session_id> <regex_hits>
set -euo pipefail
echo "Read $1 and emit punt evidence rows."
```

```bash
chmod +x scripts/punts-extract-prompt.sh
```

- [ ] **Step 5: Run the test, expect pass**

Run: `bash tests/punts/run-tests.sh`
Expected: `8 tests run, 0 failed`.

- [ ] **Step 6: Commit**

```bash
printf 'feat: fork claude -p subagent for structured punt evidence\n\nWhen the regex screen finds at least one hit and the claude binary is\non PATH, fork a backgrounded `claude -p` to extract structured\nevidence rows into .claude/punts/raw/<session>.json. Detached so the\nStop hook returns immediately. Falls back to writing regex hits if\nthe subagent fails or claude is unavailable, so evidence is never\nlost.\n\nCo-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>\n' > /tmp/cc-msg-task5.txt
git add scripts/punts-detect.sh scripts/punts-extract-prompt.sh tests/punts/test-detect.sh
git commit -F /tmp/cc-msg-task5.txt
```

---

## Task 6: Real prompt builder in `punts-extract-prompt.sh`

**Files:**
- Modify: `scripts/punts-extract-prompt.sh` (replace stub with real prompt)
- Modify: `tests/punts/test-detect.sh` (add a smoke test that the prompt contains required fields)

- [ ] **Step 1: Append the failing test**

To `tests/punts/test-detect.sh`:
```bash
test_prompt_contains_required_fields() {
  local prompt
  prompt=$(bash "$SCRIPTS_DIR/punts-extract-prompt.sh" \
    "$FIXTURES_DIR/transcript-soft-phrase.jsonl" "session-prompt-001" "regex hit example")

  for field in "evidence_quote" "claim" "files_mentioned" "subagent_confidence" "source"; do
    case "$prompt" in
      *"$field"*) printf '  ok: prompt contains %s\n' "$field"; TESTS_RUN=$((TESTS_RUN + 1)) ;;
      *) printf '  FAIL: prompt missing %s\n' "$field"; TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)) ;;
    esac
  done
}
```

- [ ] **Step 2: Run the test, expect failure**

Run: `bash tests/punts/run-tests.sh`
Expected: 5 of the 5 field assertions in the new test fail (the stub prompt does not mention any of those fields).

- [ ] **Step 3: Replace the stub with the real prompt builder**

Overwrite `scripts/punts-extract-prompt.sh`:
```bash
#!/usr/bin/env bash
# Build the prompt fed to `claude -p` for extracting punt evidence from a
# session transcript. Pure stdout — no file I/O. Called by punts-detect.sh.
#
# Args:
#   $1  transcript_path  Absolute path to the JSONL transcript.
#   $2  session_id       Session UUID.
#   $3  regex_hits       Newline-separated lines that matched the regex screen.
set -euo pipefail

transcript_path="$1"
session_id="$2"
regex_hits="$3"

ended_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"

cat <<PROMPT
You are analyzing a Claude Code session transcript to extract "punts" — issues
the assistant noticed but explicitly chose not to fix because they were
pre-existing, out of scope, or unrelated to the current change.

Read the transcript at: $transcript_path

Two signals indicate a punt:
  1. The assistant emitted a line tagged "[PUNT]: <reason>" — these are
     high-confidence, treat source="marker" and subagent_confidence="high".
  2. The assistant used soft phrasing such as "pre-existing", "out of scope",
     "unrelated to this change", "already broken", etc. — treat source="regex".
     Confidence is "medium" if a concrete file path is mentioned, "low" if not.

Skip false positives where "pre-existing" was used neutrally (e.g. "the
pre-existing tests pass" is not a punt).

Session metadata to embed in every row:
  session_id:        $session_id
  session_ended_at:  $ended_at
  branch:            $branch

For each genuine punt, emit one JSON object with these fields:
  - id (string): sha1 hex of the lowercased claim string, 40 chars.
  - session_id (string): "$session_id".
  - session_ended_at (string, ISO 8601): "$ended_at".
  - branch (string): "$branch".
  - evidence_quote (string, <=200 chars): the assistant's exact sentence.
  - context_quote (string): 1-2 surrounding lines from the transcript.
  - claim (string, <=120 chars): one-line description of what was observed.
  - files_mentioned (array of strings): "<path>:<line>" or "<path>" the
    assistant cited; empty array if none.
  - regex_hit (string): which phrase pattern matched (e.g. "pre-existing").
  - source (string): "marker" or "regex".
  - subagent_confidence (string): "high" | "medium" | "low".

Return a single JSON array. If there are no genuine punts (all hits were
false positives), return [].

Regex pre-screen hits for context (use these to anchor your reading, but do
not include any that turn out to be false positives in the output):
$regex_hits
PROMPT
```

- [ ] **Step 4: Run the test, expect pass**

Run: `bash tests/punts/run-tests.sh`
Expected: `13 tests run, 0 failed`.

- [ ] **Step 5: Commit**

```bash
printf 'feat: build real subagent prompt with full evidence schema\n\nReplaces the stub. Specifies the JSON schema each evidence row must\nconform to (id, session_id, ended_at, branch, evidence_quote,\ncontext_quote, claim, files_mentioned, regex_hit, source,\nsubagent_confidence), the marker-vs-regex confidence rubric, and\ninstructions to skip neutral uses of "pre-existing" and similar\nphrases.\n\nCo-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>\n' > /tmp/cc-msg-task6.txt
git add scripts/punts-extract-prompt.sh tests/punts/test-detect.sh
git commit -F /tmp/cc-msg-task6.txt
```

---

## Task 7: Add `[PUNT]:` marker convention to `RULEZ.md`

**Files:**
- Modify: `RULEZ.md` (append a `## Punts` section)

- [ ] **Step 1: Read current `RULEZ.md`**

Run: `cat RULEZ.md`
Expected: 12-line file with a `# RULEZ` header, a `## Compact Instructions` section, and nothing else.

- [ ] **Step 2: Append the new section**

Append to `RULEZ.md` (after the existing content):

```markdown

## Punts

When you decide an issue is out-of-scope, pre-existing, or otherwise should
not be addressed in the current change, prefer to flag it on its own line as:

    [PUNT]: <one-line description of what was observed and where>

Use this only for genuine observations you are choosing not to act on, not for
neutral references (e.g. "the pre-existing tests pass" is not a punt).
Captured punts can be reviewed later via `/rulez:punts-triage`.
```

- [ ] **Step 3: Verify the file**

Run: `tail -10 RULEZ.md`
Expected: the new section appears, with the literal `[PUNT]:` example line.

- [ ] **Step 4: Commit**

```bash
printf 'feat: document [PUNT]: marker convention in RULEZ.md\n\nSoft hint to flag out-of-scope decisions on their own line. The Stop\nhook regex matches both this marker and the soft-phrase set, so the\nmarker raises confidence on findings the assistant explicitly\ntagged.\n\nCo-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>\n' > /tmp/cc-msg-task7.txt
git add RULEZ.md
git commit -F /tmp/cc-msg-task7.txt
```

---

## Task 8: Create `/rulez:punts-triage` slash command

**Files:**
- Create: `commands/rulez/punts-triage.md`

- [ ] **Step 1: Write the command file**

Create `commands/rulez/punts-triage.md`:

```markdown
# Punts Triage

Walk the accumulated raw punt evidence interactively and promote the worthy
items into curated `.claude/punts/<slug>.md` files (one issue per file,
git-tracked).

## Instructions

1. **List raw evidence files**

```bash
ls -1t .claude/punts/raw/*.json 2>/dev/null
```

If the listing is empty, report `No untriaged punts.` and stop.

2. **Walk each file (oldest first by mtime)**

For each `*.json` file, read it and iterate the array of evidence rows.

For each row, present to the user:

- **Claim:** `<row.claim>`
- **Evidence:** `> <row.evidence_quote>`
- **Files mentioned:** `<row.files_mentioned>`
- **Source / confidence:** `<row.source> / <row.subagent_confidence>`
- **Seen in:** session `<row.session_id>` on `<row.branch>` at `<row.session_ended_at>`

Then ask: **APPROVE / REJECT / SKIP / MERGE WITH `<existing>`**.

Before APPROVE, check whether a `.claude/punts/*.md` already exists with a
matching `id` (frontmatter). If so, offer MERGE instead.

3. **APPROVE → write `.claude/punts/<slug>.md`**

- Generate a kebab-case slug from `claim`, lowercase, ≤ 64 chars, hyphens only.
- If `<slug>.md` already exists with a different id, append `-2`, `-3`, etc.
- Write the file with this template:

```markdown
---
id: <row.id>
first_seen: <row.session_ended_at YYYY-MM-DD>
last_seen: <row.session_ended_at YYYY-MM-DD>
branches: [<row.branch>]
sessions: [<row.session_id>]
status: open
source: <row.source>
confidence: <row.subagent_confidence>
---

# <claim as title>

## Evidence

> <row.evidence_quote>

(seen in session `<row.session_id>` on branch `<row.branch>` at <row.session_ended_at>)

## Files

- <each file from row.files_mentioned, one per bullet>

## Suggested next step

<ask the user what they want to do about it; record their answer here, or
your own concise recommendation if they say "you decide">
```

Then remove this row from the raw JSON file.

4. **REJECT → drop the row**

Remove this row from the raw JSON file. (Rejection is transient — if the
same `id` shows up in a future session, it will be re-presented.)

5. **SKIP → leave the row**

Move on to the next row without modifying the raw JSON.

6. **MERGE WITH `<existing>` → append to the existing `.md`**

Append a new evidence block to the existing `.md`:

```markdown

(also seen in session `<row.session_id>` on branch `<row.branch>` at <row.session_ended_at>)

> <row.evidence_quote>
```

Update the `last_seen` date in the frontmatter to today, and append the
session id to the `sessions:` array. Remove this row from the raw JSON.

7. **Clean up empty raw files**

After processing each raw file, if its rows array is now empty, delete the
file:

```bash
rm .claude/punts/raw/<file>.json
```

8. **Final report**

Summarize: `N approved, M rejected, K skipped, P merged.`

## Notes

- Process rows interactively, one at a time. Do not bulk-approve.
- The user may stop at any point; remaining rows survive in their raw JSON
  for the next triage pass.
- Curated `.md` files are git-tracked; ask the user whether to commit them
  at the end of the session.
```

- [ ] **Step 2: Verify the slash command appears in the symlink**

Run: `ls ~/.claude/commands/rulez/punts-triage.md 2>&1 | head -1`
Expected: the path or "No such file or directory" — either is acceptable. The symlink is one directory level up (`commands/rulez` itself is symlinked); the new file is reachable through it once it exists in the source.

To confirm reachability:
```bash
ls -L ~/.claude/commands/rulez/punts-triage.md 2>/dev/null && echo "reachable" || echo "missing"
```
Expected: `reachable`.

- [ ] **Step 3: Commit**

```bash
printf 'feat: /rulez:punts-triage slash command\n\nInteractive walk through .claude/punts/raw/*.json. For each evidence\nrow: APPROVE writes .claude/punts/<slug>.md (one issue per file,\ngit-tracked); REJECT drops the row; SKIP leaves it; MERGE appends to\nan existing .md when the same id resurfaces. The command itself is a\nmarkdown skill — Claude reads it on /rulez:punts-triage invocation.\n\nCo-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>\n' > /tmp/cc-msg-task8.txt
git add commands/rulez/punts-triage.md
git commit -F /tmp/cc-msg-task8.txt
```

---

## Task 9: Wire Stop hook + permissions into `settings.json` template

**Files:**
- Modify: `settings.json` (add Stop hook entry; add new bash permissions; add Skill permission)

- [ ] **Step 1: Read current `settings.json`**

Run: `cat settings.json`
Expected: existing template with `permissions`, `statusLine`, and empty `"hooks": {}`.

- [ ] **Step 2: Add the new bash permission entries**

Inside the `permissions.allow` array, add (in the section listing rulez-claudeset script paths, near the existing scripts):

```
"Bash(~/.claude/skills/rulez-claudeset/scripts/punts-detect.sh:*)",
"Bash(~/.claude/skills/rulez-claudeset/scripts/punts-extract-prompt.sh:*)",
```

And in the `Skill(rulez:*)` block, add:
```
"Skill(rulez:punts-triage)",
```

- [ ] **Step 3: Replace `"hooks": {}` with the Stop hook**

Change the trailing `"hooks": {}` to:

```json
"hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/skills/rulez-claudeset/scripts/punts-detect.sh"
          }
        ]
      }
    ]
  }
```

- [ ] **Step 4: Validate the JSON**

Run: `jq . settings.json > /dev/null && echo ok`
Expected: `ok`.

- [ ] **Step 5: Commit**

```bash
printf 'feat: ship Stop hook + punts permissions in settings template\n\nAdds the Stop hook entry that runs scripts/punts-detect.sh on every\nsession end, two new Bash permissions for the punts scripts, and the\nSkill permission for /rulez:punts-triage. bin/setup will merge these\non the next install (skipping the Stop hook if one is already\npresent — wired in the next commit).\n\nCo-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>\n' > /tmp/cc-msg-task9.txt
git add settings.json
git commit -F /tmp/cc-msg-task9.txt
```

---

## Task 10: Extend `bin/setup` to merge the Stop hook on install

**Files:**
- Modify: `bin/setup` (add a Stop-hook merge block, mirroring the existing SessionStart logic)

- [ ] **Step 1: Read current `bin/setup`**

Run: `cat bin/setup`
Expected: existing setup script with a `# SessionStart hook: skip if rulez-claudeset hook already present` block.

- [ ] **Step 2: Add the Stop-hook merge block**

Inside the `else` branch that handles existing settings (immediately after the SessionStart-hook merge block, before the `printf '%s\n' "$merged" > "$SETTINGS_DST"` line), insert:

```bash
  # Stop hook: skip if rulez-claudeset hook already present.
  has_stop_hook=$(echo "$merged" | jq -e '.hooks.Stop | map(select(.hooks[]?.command | test("rulez-claudeset"))) | length > 0' 2>/dev/null && echo yes || echo no)
  if [ "$has_stop_hook" = "no" ]; then
    merged="$(echo "$merged" | jq '
      .hooks.Stop //= [] |
      .hooks.Stop += [{
        "matcher": "",
        "hooks": [{
          "type": "command",
          "command": "bash ~/.claude/skills/rulez-claudeset/scripts/punts-detect.sh"
        }]
      }]
    ')"
    log "Added Stop hook (punts detection)"
  else
    log "Stop hook already present"
  fi
```

- [ ] **Step 3: Smoke-test the merge logic on a temp file**

```bash
tmp=$(mktemp -d)
cp settings.json "$tmp/dst.json"
# Run a slimmed-down version of the merge by hand to confirm jq syntax.
jq '
  .hooks.Stop //= [] |
  .hooks.Stop += [{
    "matcher": "",
    "hooks": [{
      "type": "command",
      "command": "bash ~/.claude/skills/rulez-claudeset/scripts/punts-detect.sh"
    }]
  }]
' "$tmp/dst.json" > "$tmp/out.json"
jq '.hooks.Stop | length' "$tmp/out.json"
rm -rf "$tmp"
```

Expected output: `2` (because settings.json already has the hook from Task 9, and the merge appends a second copy — which is fine for syntax validation; the real `has_stop_hook` guard prevents duplication in the actual install path).

- [ ] **Step 4: Run `bash bin/setup -q` to confirm it does not error**

Run: `bash bin/setup -q`
Expected: it logs "Stop hook already present" (because the user's `~/.claude/settings.json` may already have the rulez-claudeset Stop hook from a prior install, OR it logs "Added Stop hook (punts detection)" on a clean install). No errors.

- [ ] **Step 5: Commit**

```bash
printf 'feat: bin/setup merges Stop hook for punts detection\n\nMirrors the existing SessionStart-hook merge: if the user already\nhas a rulez-claudeset Stop hook, leave it alone; otherwise append\nthe new entry to .hooks.Stop. Idempotent across reinstalls.\n\nCo-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>\n' > /tmp/cc-msg-task10.txt
git add bin/setup
git commit -F /tmp/cc-msg-task10.txt
```

---

## Task 11: Bump `VERSION` and write `UPGRADE.md` section

**Files:**
- Modify: `VERSION` (`1.1.4` → `1.2.0`)
- Modify: `UPGRADE.md` (new `## To v1.2.0 — from v1.1.4` section at the top)

- [ ] **Step 1: Bump `VERSION`**

Overwrite `VERSION`:
```
1.2.0
```

- [ ] **Step 2: Add the UPGRADE.md section**

Insert at the very top of `UPGRADE.md` (immediately after the `# Upgrade Guide` line):

```markdown

## To v1.2.0 — from v1.1.4

Additive feature release. No breaking changes. Re-run `bin/setup` (or let the
SessionStart auto-update do it) to pick up the new Stop hook.

### What's new

- **Punt detection.** Sessions now end with a regex screen of the transcript
  for "pre-existing", "out of scope", and similar phrasing — plus the
  explicit `[PUNT]: <reason>` marker (now documented in `RULEZ.md`). When at
  least one hit is found, a backgrounded `claude -p` extracts structured
  evidence into `.claude/punts/raw/<session-uuid>.json`. The hook returns
  immediately so the UI is not blocked. If `claude` is not on PATH, the raw
  regex hits are written instead so evidence is never lost.
- **Triage on demand.** New `/rulez:punts-triage` slash command walks the
  accumulated raw evidence interactively. APPROVE writes a curated
  `.claude/punts/<slug>.md` (git-tracked, one issue per file); REJECT drops
  the row; SKIP leaves it for next time; MERGE appends to an existing `.md`
  when the same `id` (SHA-1 of the claim) resurfaces.
- **`RULEZ.md` addition.** New `## Punts` section asking Claude to flag
  out-of-scope decisions as `[PUNT]: <reason>` on their own line. Soft hint —
  the regex catches both marked and un-marked punts.

### Project-level housekeeping

The runtime data lives under `<project>/.claude/punts/`:

- `.claude/punts/raw/` — transient evidence; safe to delete.
- `.claude/punts/<slug>.md` — curated knowledge.

Most projects already gitignore `.claude/` wholesale; if you want to track
the curated `.md` files in git, narrow the ignore to:

```
.claude/*
!.claude/punts/
.claude/punts/raw/
```

### Disabling

If you do not want the Stop hook, edit `~/.claude/settings.json` and remove
the `Stop` entry whose command references `rulez-claudeset/scripts/punts-detect.sh`.
`bin/setup` will not re-add it on subsequent runs as long as a hook with that
command path exists, so removing it is sticky.

---
```

(Note: the trailing `---` terminates this section so the existing `## To v1.1.4` section that follows it remains visually separated.)

- [ ] **Step 3: Verify both files**

```bash
cat VERSION
head -40 UPGRADE.md
```
Expected: VERSION shows `1.2.0`; UPGRADE.md begins with the new section.

- [ ] **Step 4: Run all tests one final time**

Run: `bash tests/punts/run-tests.sh`
Expected: `13 tests run, 0 failed`.

- [ ] **Step 5: Commit (release)**

```bash
printf 'chore: release v1.2.0\n\nShips punt detection (Stop hook) and the /rulez:punts-triage\nworkflow.\n\nCo-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>\n' > /tmp/cc-msg-task11.txt
git add VERSION UPGRADE.md
git commit -F /tmp/cc-msg-task11.txt
```

---

## Task 12: Push and pull into the global install

**Files:** none (operational task).

- [ ] **Step 1: Push to origin**

```bash
git push origin main
```

- [ ] **Step 2: Pull into the global install**

```bash
~/.claude/skills/rulez-claudeset/bin/auto-update.sh || true
git -C ~/.claude/skills/rulez-claudeset fetch origin main
git -C ~/.claude/skills/rulez-claudeset pull --ff-only origin main
~/.claude/skills/rulez-claudeset/bin/setup
```

- [ ] **Step 3: Verify the global install picked up the new files**

```bash
ls ~/.claude/skills/rulez-claudeset/scripts/punts-*.sh
ls ~/.claude/commands/rulez/punts-triage.md
cat ~/.claude/skills/rulez-claudeset/VERSION
jq '.hooks.Stop' ~/.claude/settings.json
```
Expected:
- both `punts-detect.sh` and `punts-extract-prompt.sh` listed.
- `punts-triage.md` listed.
- VERSION shows `1.2.0`.
- `.hooks.Stop` is an array containing the rulez-claudeset entry (or `null` if `bin/setup` ran in a state where it judged the user had a custom hook — re-run `bin/setup` if so and re-check).

- [ ] **Step 4: Manual smoke test in a real session**

Open a fresh Claude Code session in any project. Have a short interaction
where the assistant says something like "this auth issue is pre-existing —
leaving it for later". End the session.

Within ~10 seconds, check:
```bash
ls .claude/punts/raw/
```
Expected: a file named `<session-uuid>.json` exists. Inspect it with `jq .`
to confirm the structure.

Then run `/rulez:punts-triage` in a new session and walk through the
evidence interactively.

---

## Self-review

Performed against the spec at `docs/superpowers/specs/2026-05-06-punt-detection-design.md`.

**Spec coverage:**
- Stop hook regex screen (soft phrases + `[PUNT]:`) — Tasks 3, 4.
- Backgrounded `claude -p` subagent — Task 5.
- Regex-only fallback when `claude` missing — Task 5 (else branch).
- Subagent prompt with full schema — Task 6.
- `RULEZ.md` marker convention — Task 7.
- `/rulez:punts-triage` command — Task 8.
- `settings.json` Stop hook + permissions — Task 9.
- `bin/setup` merge logic — Task 10.
- VERSION + UPGRADE.md release notes — Task 11.
- Push + global install + smoke test — Task 12.
- Per-session JSON file at `.claude/punts/raw/<session-uuid>.json` — covered in Task 3 (cwd-relative).
- Atomic write via `.tmp` + `mv` — covered in Tasks 3 and 5.
- `id = sha1(claim)` claim-only hash — instructed in the prompt (Task 6); not enforced in code because the subagent emits the id.
- Curated `.md` template — covered in Task 8 (slash command instructions).
- Edge case: hook fires before transcript flushed — covered in Task 2 (defensive `[ ! -f "$transcript_path" ] && exit 0`).
- Edge case: parallel sessions — covered by per-session filename (Task 3).
- Edge case: `claude` missing → fallback — covered in Task 5.
- Edge case: subagent invalid JSON → `.tmp` left behind — covered in Task 5 (`mv` only on success; failure path writes `subagent-failed` fallback).
- Triage interrupted mid-run — covered in Task 8 (SKIP-ed rows persist; row-level removal not file-level).
- Same punt across N sessions → MERGE — covered in Task 8.
- `.claude/punts/<slug>.md` collision — covered in Task 8 (suffix increment).
- Hook timing budget < 200ms — addressed by background-fork pattern in Task 5; explicit timing assertion is omitted from tests because the bg-fork pattern guarantees the hook returns immediately by construction.

**Placeholder scan:** no TBD/TODO/"add appropriate error handling"/"similar to" entries. Every code step has a complete code block.

**Type consistency:**
- `transcript_path`, `session_id`, `hits`, `out` variable names consistent across Tasks 2-5.
- `PUNT_PHRASES` regex extended in Task 4, not redefined.
- `install_fake_claude` and `wait_for_file` declared in Task 1 helpers, used in Task 5 test.
- Field names (`id`, `claim`, `evidence_quote`, `source`, `subagent_confidence`) consistent between fixtures (Task 5 fake-claude payload), the prompt (Task 6), and the triage command (Task 8).
