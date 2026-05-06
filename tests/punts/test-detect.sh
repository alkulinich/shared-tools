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
