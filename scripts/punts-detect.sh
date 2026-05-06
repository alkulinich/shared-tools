#!/usr/bin/env bash
# Stop hook for Claude Code sessions. When the assistant declines to fix an
# issue (calling it pre-existing, out of scope, etc., or marking it [PUNT]:),
# capture evidence to .claude/punts/raw/<session>-<offset>-<pid>.json for
# later triage.
#
# Inputs (stdin JSON):
#   .transcript_path  Absolute path to the session's JSONL transcript.
#   .session_id       Stable UUID identifying the session.
#
# State:
#   .claude/punts/state/<session_id>.offset
#     Last byte offset of the transcript that has already been screened.
#     Each Stop run only processes bytes added since this value, so the cost
#     stays roughly constant per turn instead of growing with session length.
#
# Outputs:
#   .claude/punts/raw/<session_id>-<offset>-<pid>.json
#     Written only when the new window contains regex hits. The synchronous
#     write is regex-only fallback JSON; if `claude` is on PATH the structured
#     subagent output is written over it via .tmp + mv on success.
#
# Behavior:
#   1. Load stored offset (default 0). Snapshot transcript size as new_offset.
#   2. If transcript shrank (compaction), reset stored offset to 0.
#   3. If no new bytes, exit 0 silently.
#   4. Regex-screen the new byte window for [PUNT]: marker or soft phrasing.
#   5. Persist new_offset to state file atomically (so the offset advance is
#      durable even if the subagent fork later dies).
#   6. If hits, synchronously write the regex-only fallback artifact, then
#      optionally fork `claude -p` to overwrite it with structured evidence.
#
# See docs/superpowers/specs/2026-05-06-punt-detection-design.md.
set -euo pipefail

input=$(cat)
transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')
session_id=$(echo "$input" | jq -r '.session_id // empty')

# Bail if transcript is missing (Stop can fire before flush).
[ -z "$transcript_path" ] && exit 0
[ ! -f "$transcript_path" ] && exit 0

# Per-session byte-offset checkpoint. cwd is project root for Stop hooks.
STATE_DIR=".claude/punts/state"
state_file="$STATE_DIR/${session_id}.offset"
mkdir -p "$STATE_DIR"

stored_offset=0
if [ -f "$state_file" ]; then
  stored_offset=$(cat "$state_file" 2>/dev/null || echo 0)
fi
case "$stored_offset" in ''|*[!0-9]*) stored_offset=0 ;; esac

new_offset=$(wc -c < "$transcript_path" | tr -d ' ')

# Compaction or rotation rewrote the transcript — start from byte 0.
[ "$new_offset" -lt "$stored_offset" ] && stored_offset=0

# No new content since last run.
[ "$new_offset" -eq "$stored_offset" ] && exit 0

bytes_to_read=$((new_offset - stored_offset))

# Regex screen for soft phrases that signal a punt. Case-insensitive.
PUNT_PHRASES='\[PUNT\]:|pre-existing|pre existing|already broken|out of scope|not related to (this|the change)|unrelated to (this|the change)|existing (issue|bug)|leave (this|that|it) for later|leaving (this|that) (for now|alone)|outside (the|this) scope'

# Look only at assistant messages — user input is irrelevant for punt detection.
# `jq -r` outputs raw strings (no JSON quoting) so the matched lines do not get
# double-quoted when re-encoded into the fallback JSON below.
hits=$(tail -c +$((stored_offset + 1)) "$transcript_path" \
  | head -c "$bytes_to_read" \
  | jq -r 'select(.type=="assistant") | .message.content // empty' 2>/dev/null \
  | grep -iE "$PUNT_PHRASES" || true)

# Advance offset regardless of hits — these bytes have been screened and we do
# not want to re-screen them on the next Stop fire.
printf '%s\n' "$new_offset" > "$state_file.tmp"
mv "$state_file.tmp" "$state_file"

# No hits → state advanced, nothing else to do.
[ -z "$hits" ] && exit 0

# Ensure the project punts directory exists.
mkdir -p .claude/punts/raw

# Per-run output file. new_offset is monotonic per session so it sorts
# lexicographically; PID disambiguates the rare concurrent Stop fire.
out=".claude/punts/raw/${session_id}-$(printf '%012d' "$new_offset")-$$.json"

# Synchronous regex-only write — guarantees the artifact exists before we fork
# the subagent, so a hit is never lost even if `claude -p` dies or hangs.
jq -n --arg hits "$hits" '{regex_hits: $hits, fallback: "regex-only"}' > "$out.tmp"
mv "$out.tmp" "$out"

# Resolve claude binary location. If unavailable, the regex-only file written
# above is the final artifact.
CLAUDE_BIN="$(command -v claude || true)"

if [ -n "$CLAUDE_BIN" ]; then
  # Subagent path — extract structured evidence in the background and overwrite
  # the regex-only fallback on success. On failure leave the fallback in place.
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  prompt="$(bash "$SCRIPT_DIR/punts-extract-prompt.sh" "$transcript_path" "$session_id" "$hits")"
  (
    "$CLAUDE_BIN" -p "$prompt" --output-format json --max-turns 1 \
      > "$out.tmp" 2>/dev/null \
    && mv "$out.tmp" "$out" \
    || rm -f "$out.tmp"
  ) &
  disown
fi
exit 0
