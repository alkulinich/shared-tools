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

test_soft_phrase_writes_fallback() {
  local proj transcript stdin out
  proj="$(make_temp_project)"
  transcript="$FIXTURES_DIR/transcript-soft-phrase.jsonl"
  stdin="$(make_stdin "$transcript" "session-soft-001")"
  out="$proj/.claude/punts/raw/session-soft-001.json"

  # Override PATH so claude binary is not found — exercises fallback path.
  ( cd "$proj" && export PATH="/usr/bin:/bin" && printf '%s' "$stdin" | bash "$SCRIPTS_DIR/punts-detect.sh" )

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

test_marker_detected() {
  local proj transcript stdin out
  proj="$(make_temp_project)"
  transcript="$FIXTURES_DIR/transcript-marker.jsonl"
  stdin="$(make_stdin "$transcript" "session-marker-001")"
  out="$proj/.claude/punts/raw/session-marker-001.json"

  ( cd "$proj" && export PATH="/usr/bin:/bin" && printf '%s' "$stdin" | bash "$SCRIPTS_DIR/punts-detect.sh" )

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

  ( cd "$proj" && export PATH="$fake_bin:$PATH" && printf '%s' "$stdin" | bash "$SCRIPTS_DIR/punts-detect.sh" )

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
