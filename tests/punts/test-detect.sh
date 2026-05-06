#!/usr/bin/env bash
# Tests for scripts/punts-detect.sh.

test_clean_transcript_writes_no_file() {
  local proj transcript stdin
  proj="$(make_temp_project)"
  transcript="$FIXTURES_DIR/transcript-clean.jsonl"
  stdin="$(make_stdin "$transcript" "session-clean-001")"

  ( cd "$proj" && printf '%s' "$stdin" | bash "$SCRIPTS_DIR/punts-detect.sh" )

  local raw_count
  raw_count=$(count_raw_files "$proj" "session-clean-001")
  assert_eq "0" "$raw_count" "clean transcript: no raw JSON written"
  rm -rf "$proj"
}

test_soft_phrase_writes_fallback() {
  local proj transcript stdin out
  proj="$(make_temp_project)"
  transcript="$FIXTURES_DIR/transcript-soft-phrase.jsonl"
  stdin="$(make_stdin "$transcript" "session-soft-001")"

  # Override PATH so claude binary is not found — exercises fallback path.
  ( cd "$proj" && export PATH="/usr/bin:/bin" && printf '%s' "$stdin" | bash "$SCRIPTS_DIR/punts-detect.sh" )

  out="$(find_raw_file "$proj" "session-soft-001")"
  assert_file_exists "$out" "soft-phrase: regex fallback JSON written"
  if [ -n "$out" ] && [ -f "$out" ]; then
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

test_marker_detected() {
  local proj transcript stdin out
  proj="$(make_temp_project)"
  transcript="$FIXTURES_DIR/transcript-marker.jsonl"
  stdin="$(make_stdin "$transcript" "session-marker-001")"

  ( cd "$proj" && export PATH="/usr/bin:/bin" && printf '%s' "$stdin" | bash "$SCRIPTS_DIR/punts-detect.sh" )

  out="$(find_raw_file "$proj" "session-marker-001")"
  assert_file_exists "$out" "marker: regex fallback JSON written"
  if [ -n "$out" ] && [ -f "$out" ]; then
    local hits
    hits=$(jq -r '.regex_hits // empty' "$out")
    case "$hits" in
      *'[PUNT]:'*) printf '  ok: marker: regex_hits contains [PUNT]:\n'; TESTS_RUN=$((TESTS_RUN + 1)) ;;
      *) printf '  FAIL: marker: regex_hits missing [PUNT]:\n'; TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)) ;;
    esac
  fi
  rm -rf "$proj"
}

test_subagent_writes_structured_json() {
  local proj transcript stdin out fake_bin fake_payload
  proj="$(make_temp_project)"
  transcript="$FIXTURES_DIR/transcript-soft-phrase.jsonl"
  stdin="$(make_stdin "$transcript" "session-subagent-001")"

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

  ( cd "$proj" && export PATH="$fake_bin:$PATH" && printf '%s' "$stdin" | bash "$SCRIPTS_DIR/punts-detect.sh" )

  # The synchronous regex-only write makes the file appear immediately, then
  # the backgrounded subagent overwrites it. Poll until the structured array
  # shape lands instead of just waiting for file existence.
  out="$(find_raw_file "$proj" "session-subagent-001")"
  if [ -z "$out" ]; then
    printf '  FAIL: subagent: raw file did not appear\n'
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    rm -rf "$proj"
    return
  fi

  if wait_for_jq_value "$out" '.[0].id // empty' \
       "0000000000000000000000000000000000000001" 5; then
    printf '  ok: subagent: structured JSON id passed through\n'
    TESTS_RUN=$((TESTS_RUN + 1))
  else
    printf '  FAIL: subagent: structured JSON id did not appear within 5s\n'
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
  rm -rf "$proj"
}

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

test_offset_state_written_after_run() {
  local proj transcript stdin sid expected actual
  proj="$(make_temp_project)"
  transcript="$FIXTURES_DIR/transcript-soft-phrase.jsonl"
  sid="session-offset-001"
  stdin="$(make_stdin "$transcript" "$sid")"

  ( cd "$proj" && export PATH="/usr/bin:/bin" && printf '%s' "$stdin" | bash "$SCRIPTS_DIR/punts-detect.sh" )

  expected=$(wc -c < "$transcript" | tr -d ' ')
  actual="$(read_offset "$proj/.claude/punts/state/${sid}.offset")"
  assert_eq "$expected" "$actual" "offset state: equals transcript byte size after run"
  rm -rf "$proj"
}

test_no_new_bytes_writes_nothing() {
  local proj transcript stdin sid before after offset_before offset_after
  proj="$(make_temp_project)"
  transcript="$FIXTURES_DIR/transcript-soft-phrase.jsonl"
  sid="session-idempotent-001"
  stdin="$(make_stdin "$transcript" "$sid")"

  # First run captures hits and advances offset.
  ( cd "$proj" && export PATH="/usr/bin:/bin" && printf '%s' "$stdin" | bash "$SCRIPTS_DIR/punts-detect.sh" )
  before=$(count_raw_files "$proj" "$sid")
  offset_before="$(read_offset "$proj/.claude/punts/state/${sid}.offset")"

  # Second run with no new bytes — must produce no additional file.
  ( cd "$proj" && export PATH="/usr/bin:/bin" && printf '%s' "$stdin" | bash "$SCRIPTS_DIR/punts-detect.sh" )
  after=$(count_raw_files "$proj" "$sid")
  offset_after="$(read_offset "$proj/.claude/punts/state/${sid}.offset")"

  assert_eq "$before" "$after" "idempotent: second run wrote no new raw file"
  assert_eq "$offset_before" "$offset_after" "idempotent: offset unchanged on no-new-bytes run"
  rm -rf "$proj"
}

test_new_bytes_written_only_for_new_window() {
  local proj transcript stdin sid first_count second_count out hits
  proj="$(make_temp_project)"
  sid="session-incremental-001"

  # Copy the clean (no-hits) fixture into a writable transcript.
  transcript="$proj/transcript.jsonl"
  cat "$FIXTURES_DIR/transcript-clean.jsonl" > "$transcript"
  stdin="$(make_stdin "$transcript" "$sid")"

  # First run: clean fixture, no hits, offset advances to file size.
  ( cd "$proj" && export PATH="/usr/bin:/bin" && printf '%s' "$stdin" | bash "$SCRIPTS_DIR/punts-detect.sh" )
  first_count=$(count_raw_files "$proj" "$sid")
  assert_eq "0" "$first_count" "incremental: first (clean) run wrote no raw file"

  # Append a new assistant message containing a punt phrase.
  printf '{"type":"assistant","message":{"content":"the auth code is pre-existing, leaving it for later"}}\n' >> "$transcript"

  # Second run: only the new line should be screened.
  ( cd "$proj" && export PATH="/usr/bin:/bin" && printf '%s' "$stdin" | bash "$SCRIPTS_DIR/punts-detect.sh" )
  second_count=$(count_raw_files "$proj" "$sid")
  assert_eq "1" "$second_count" "incremental: second run wrote exactly one new raw file"

  out="$(find_raw_file "$proj" "$sid")"
  if [ -n "$out" ] && [ -f "$out" ]; then
    hits=$(jq -r '.regex_hits // empty' "$out")
    case "$hits" in
      *pre-existing*) printf '  ok: incremental: new hit captured\n'; TESTS_RUN=$((TESTS_RUN + 1)) ;;
      *) printf '  FAIL: incremental: new hit missing from regex_hits\n'; TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)) ;;
    esac
  fi
  rm -rf "$proj"
}

test_invalid_subagent_output_falls_back_to_regex() {
  local proj transcript stdin sid fake_bin out fallback i
  proj="$(make_temp_project)"
  transcript="$FIXTURES_DIR/transcript-soft-phrase.jsonl"
  sid="session-invalid-001"
  stdin="$(make_stdin "$transcript" "$sid")"

  # Fake claude that "succeeds" (exit 0) but emits garbage that isn't valid
  # JSON — simulates the truncated-output failure mode. The hook should
  # detect this via jq -e and leave the synchronous regex-only fallback in
  # place rather than overwriting it with the garbage.
  fake_bin="$proj/bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/claude" <<'EOF'
#!/usr/bin/env bash
printf 'this is not valid json {{{ truncated...'
exit 0
EOF
  chmod +x "$fake_bin/claude"

  ( cd "$proj" && export PATH="$fake_bin:$PATH" && printf '%s' "$stdin" | bash "$SCRIPTS_DIR/punts-detect.sh" )

  out="$(find_raw_file "$proj" "$sid")"
  if [ -z "$out" ]; then
    printf '  FAIL: invalid-subagent: no raw file found\n'
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    rm -rf "$proj"
    return
  fi

  # Wait briefly for the backgrounded subshell to attempt enrichment + reject it.
  i=0
  while [ "$i" -lt 30 ]; do
    [ ! -f "$out.tmp" ] && break
    sleep 0.1
    i=$((i + 1))
  done

  fallback=$(jq -r '.fallback // empty' "$out" 2>/dev/null)
  assert_eq "regex-only" "$fallback" "invalid-subagent: regex-only fallback retained on garbage output"
  rm -rf "$proj"
}

test_chunking_produces_multiple_raw_files() {
  local proj transcript stdin sid count i
  proj="$(make_temp_project)"
  sid="session-chunking-001"
  transcript="$proj/transcript.jsonl"

  # Five full JSONL assistant lines, each ~127 bytes. With PUNT_MAX_CHUNK=200
  # (and zero lookback) several chunks line up with line boundaries and emit
  # hits. Don't assert on the exact count — we just need >= 2 to confirm that
  # chunking actually fans out instead of producing one giant raw file.
  for i in 1 2 3 4 5; do
    printf '{"type":"assistant","message":{"content":"message %d says the auth thing is pre-existing and out of scope, leaving it for later"}}\n' "$i"
  done > "$transcript"

  stdin="$(make_stdin "$transcript" "$sid")"

  ( cd "$proj" && export PATH="/usr/bin:/bin" PUNT_MAX_CHUNK=200 PUNT_LOOKBACK=0 \
    && printf '%s' "$stdin" | bash "$SCRIPTS_DIR/punts-detect.sh" )

  count=$(count_raw_files "$proj" "$sid")
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$count" -ge 2 ]; then
    printf '  ok: chunking: %d raw files written for multi-chunk transcript\n' "$count"
  else
    printf '  FAIL: chunking: only %d raw file(s) written, expected >= 2\n' "$count"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
  rm -rf "$proj"
}

test_subagent_receives_slice_path_not_full_transcript() {
  local proj transcript stdin sid fake_bin captured fake_payload i
  proj="$(make_temp_project)"
  transcript="$FIXTURES_DIR/transcript-soft-phrase.jsonl"
  sid="session-slice-001"
  stdin="$(make_stdin "$transcript" "$sid")"

  fake_bin="$proj/bin"
  captured="$proj/captured-args.txt"
  fake_payload="$proj/fake.json"
  echo '[]' > "$fake_payload"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/claude" <<EOF
#!/usr/bin/env bash
# Record the prompt arg so the test can assert on its content.
printf '%s\n' "\$@" > "$captured"
cat "$fake_payload"
EOF
  chmod +x "$fake_bin/claude"

  ( cd "$proj" && export PATH="$fake_bin:$PATH" && printf '%s' "$stdin" | bash "$SCRIPTS_DIR/punts-detect.sh" )

  # Wait for the backgrounded subshell to invoke fake claude.
  i=0
  while [ ! -f "$captured" ] && [ "$i" -lt 30 ]; do
    sleep 0.1
    i=$((i + 1))
  done

  TESTS_RUN=$((TESTS_RUN + 1))
  if [ -f "$captured" ] && grep -q "slice-${sid}-" "$captured"; then
    printf '  ok: subagent prompt references slice file (not full transcript)\n'
  else
    printf '  FAIL: subagent prompt did not reference slice file\n'
    [ -f "$captured" ] && printf '    captured: %s\n' "$(cat "$captured")"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
  rm -rf "$proj"
}

test_slice_files_cleaned_up() {
  local proj transcript stdin sid fake_bin fake_payload remaining i
  proj="$(make_temp_project)"
  transcript="$FIXTURES_DIR/transcript-soft-phrase.jsonl"
  sid="session-cleanup-001"
  stdin="$(make_stdin "$transcript" "$sid")"

  fake_bin="$proj/bin"
  fake_payload="$proj/fake.json"
  echo '[]' > "$fake_payload"
  install_fake_claude "$fake_bin" "$fake_payload"

  ( cd "$proj" && export PATH="$fake_bin:$PATH" && printf '%s' "$stdin" | bash "$SCRIPTS_DIR/punts-detect.sh" )

  # Wait up to 3s for the backgrounded subshell to finish and clean up slices.
  i=0
  while [ "$i" -lt 30 ]; do
    remaining=$(ls "$proj"/.claude/punts/state/slice-"${sid}"-* 2>/dev/null | wc -l | tr -d ' ')
    [ "$remaining" -eq 0 ] && break
    sleep 0.1
    i=$((i + 1))
  done

  remaining=$(ls "$proj"/.claude/punts/state/slice-"${sid}"-* 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "0" "$remaining" "cleanup: slice files removed after subagent ran"
  rm -rf "$proj"
}

test_shrinkage_resets_offset() {
  local proj transcript stdin sid expected actual out
  proj="$(make_temp_project)"
  transcript="$FIXTURES_DIR/transcript-marker.jsonl"
  sid="session-shrink-001"
  stdin="$(make_stdin "$transcript" "$sid")"

  # Pre-write an offset larger than the transcript to simulate compaction
  # (transcript was rewritten and is now smaller than what we previously saw).
  mkdir -p "$proj/.claude/punts/state"
  echo 999999999 > "$proj/.claude/punts/state/${sid}.offset"

  ( cd "$proj" && export PATH="/usr/bin:/bin" && printf '%s' "$stdin" | bash "$SCRIPTS_DIR/punts-detect.sh" )

  expected=$(wc -c < "$transcript" | tr -d ' ')
  actual="$(read_offset "$proj/.claude/punts/state/${sid}.offset")"
  assert_eq "$expected" "$actual" "shrinkage: offset reset to actual transcript size"

  out="$(find_raw_file "$proj" "$sid")"
  assert_file_exists "$out" "shrinkage: raw file written after reset"
  rm -rf "$proj"
}
