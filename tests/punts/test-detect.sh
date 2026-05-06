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

test_no_sigpipe_on_large_transcript() {
  # Regression: when a transcript is bigger than the pipe buffer (~64 KB),
  # `tail -c +X | head -c Y` triggers SIGPIPE on tail because head closes
  # the pipe after Y bytes while tail still has more to write. Under
  # `set -euo pipefail`, that 141 propagates and the whole script aborts.
  # The fix was `|| true` on each tail|head pipeline inside read_window /
  # the slice extract. Build a >100 KB transcript with 8 KB chunks so the
  # pipe buffer overflows, and assert exit 0.
  local proj transcript stdin sid result i
  proj="$(make_temp_project)"
  sid="session-sigpipe-001"
  transcript="$proj/transcript.jsonl"

  # 500 lines of ~200 bytes each ≈ 100 KB. No punt phrases — we only care
  # that the script gets through the chunk loop without exit 141.
  for i in $(seq 1 500); do
    printf '{"type":"assistant","message":{"content":"line %d normal text with padding to reach roughly two hundred bytes per line for a total over one hundred kilobytes which is comfortably above the pipe buffer threshold"}}\n' "$i"
  done > "$transcript"

  stdin="$(make_stdin "$transcript" "$sid")"

  # The runner uses `set -uo pipefail` (no -e), so a non-zero subshell exit
  # just sets $? and execution continues — no toggle needed.
  ( cd "$proj" && export PATH="/usr/bin:/bin" PUNT_MAX_CHUNK=8192 PUNT_LOOKBACK=0 \
    && printf '%s' "$stdin" | bash "$SCRIPTS_DIR/punts-detect.sh" )
  result=$?

  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$result" -eq 0 ]; then
    printf '  ok: sigpipe-tolerance: script exited 0 on >100 KB / 8 KB-chunk transcript\n'
  else
    printf '  FAIL: sigpipe-tolerance: script exited %d (expected 0 — likely SIGPIPE regression)\n' "$result"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
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

test_slice_files_persist_for_enrich() {
  # As of v1.3.0 the Stop hook does NOT spawn `claude -p`; subagent enrichment
  # is deferred to scripts/punts-enrich.sh. Slice files must survive the hook
  # so enrich can read them later.
  local proj transcript stdin sid count
  proj="$(make_temp_project)"
  transcript="$FIXTURES_DIR/transcript-soft-phrase.jsonl"
  sid="session-persist-001"
  stdin="$(make_stdin "$transcript" "$sid")"

  ( cd "$proj" && export PATH="/usr/bin:/bin" && printf '%s' "$stdin" | bash "$SCRIPTS_DIR/punts-detect.sh" )

  count=$(ls "$proj"/.claude/punts/state/slice-"${sid}"-* 2>/dev/null | wc -l | tr -d ' ')
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$count" -ge 1 ]; then
    printf '  ok: persist: %d slice file(s) retained for enrich\n' "$count"
  else
    printf '  FAIL: persist: no slice files retained — enrich would have nothing to read\n'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
  rm -rf "$proj"
}

test_hook_does_not_spawn_claude() {
  # Regression: v1.3.0 strips the subagent fork from the hook entirely. A fake
  # claude that records its invocation should NEVER be called.
  local proj transcript stdin sid fake_bin invocation_log
  proj="$(make_temp_project)"
  transcript="$FIXTURES_DIR/transcript-soft-phrase.jsonl"
  sid="session-no-claude-001"
  stdin="$(make_stdin "$transcript" "$sid")"

  fake_bin="$proj/bin"
  invocation_log="$proj/claude-was-called.txt"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/claude" <<EOF
#!/usr/bin/env bash
echo "called" >> "$invocation_log"
echo '[]'
EOF
  chmod +x "$fake_bin/claude"

  ( cd "$proj" && export PATH="$fake_bin:$PATH" && printf '%s' "$stdin" | bash "$SCRIPTS_DIR/punts-detect.sh" )

  # Tiny grace period in case some leftover background path tries to fire.
  sleep 0.3

  TESTS_RUN=$((TESTS_RUN + 1))
  if [ ! -f "$invocation_log" ]; then
    printf '  ok: hook did not spawn claude\n'
  else
    printf '  FAIL: hook spawned claude (invocation_log exists)\n'
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
  rm -rf "$proj"
}

test_raw_file_embeds_session_id() {
  # punts-enrich.sh recovers session_id from .session_id in the raw file
  # (UUIDs contain dashes, so basename-parsing is fragile). The hook must
  # embed it in every regex-only fallback row.
  local proj transcript stdin sid out raw_sid
  proj="$(make_temp_project)"
  transcript="$FIXTURES_DIR/transcript-soft-phrase.jsonl"
  sid="session-embed-sid-001"
  stdin="$(make_stdin "$transcript" "$sid")"

  ( cd "$proj" && export PATH="/usr/bin:/bin" && printf '%s' "$stdin" | bash "$SCRIPTS_DIR/punts-detect.sh" )

  out="$(find_raw_file "$proj" "$sid")"
  raw_sid=$(jq -r '.session_id // empty' "$out" 2>/dev/null)
  assert_eq "$sid" "$raw_sid" "raw file embeds session_id for enrich"
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
