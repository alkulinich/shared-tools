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

# Regex screen for soft phrases that signal a punt. Case-insensitive.
PUNT_PHRASES='\[PUNT\]:|pre-existing|pre existing|already broken|out of scope|not related to (this|the change)|unrelated to (this|the change)|existing (issue|bug)|leave (this|that|it) for later|leaving (this|that) (for now|alone)|outside (the|this) scope'

# Look only at assistant messages — user input is irrelevant for punt detection.
# `jq -r` outputs raw strings (no JSON quoting) so the matched lines do not get
# double-quoted when re-encoded into the fallback JSON below.
hits=$(jq -r 'select(.type=="assistant") | .message.content // empty' "$transcript_path" 2>/dev/null \
  | grep -iE "$PUNT_PHRASES" || true)

# No hits → nothing to capture.
[ -z "$hits" ] && exit 0

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
