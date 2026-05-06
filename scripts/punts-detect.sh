#!/usr/bin/env bash
# Stop hook for Claude Code sessions. Synchronously captures regex-only
# evidence of "punts" (issues the assistant declined to fix as pre-existing,
# out of scope, etc.). Subagent enrichment is deferred to punts-enrich.sh —
# the hook does NOT spawn `claude -p` itself, so it returns in milliseconds
# even on long-running sessions with many chunks.
#
# Inputs (stdin JSON):
#   .transcript_path  Absolute path to the session's JSONL transcript.
#   .session_id       Stable UUID identifying the session.
#
# State:
#   .claude/punts/state/<session_id>.offset
#     Last byte offset of the transcript that has already been screened.
#   .claude/punts/state/slice-<session_id>-<chunk_end>-<pid>.jsonl
#     Per-chunk byte slice of the new window (with a small lookback). Kept
#     on disk until punts-enrich.sh consumes it.
#
# Outputs:
#   .claude/punts/raw/<session_id>-<chunk_end>-<pid>.json
#     One per chunk that contains regex hits. Always regex-only fallback —
#     punts-enrich.sh promotes these to structured rows by spawning the
#     subagent against the matching slice file.
#
# Tunables (env):
#   PUNT_MAX_CHUNK   Max bytes per chunk (default 256K).
#   PUNT_LOOKBACK    Bytes of pre-chunk context kept in the slice (default 4K).
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

# Bloom-filter screen across the whole new window. Cheap (jq+grep over raw
# bytes) and lets us short-circuit the no-hits common case before doing any
# slicing or directory creation.
window_hits=$(tail -c +$((stored_offset + 1)) "$transcript_path" \
  | head -c "$bytes_to_read" \
  | jq -r 'select(.type=="assistant") | .message.content // empty' 2>/dev/null \
  | grep -iE "$PUNT_PHRASES" || true)

# Advance offset regardless of hits — these bytes have been screened.
printf '%s\n' "$new_offset" > "$state_file.tmp"
mv "$state_file.tmp" "$state_file"

# No hits anywhere in the new window → state advanced, nothing else to do.
[ -z "$window_hits" ] && exit 0

mkdir -p .claude/punts/raw

# Chunk parameters (env-overridable for tests / power users).
MAX_CHUNK=${PUNT_MAX_CHUNK:-$((256 * 1024))}
LOOKBACK=${PUNT_LOOKBACK:-$((4 * 1024))}

# Read bytes [start, start+size) from the transcript. If `start` lands mid-line
# (i.e., the byte at `start - 1` is not '\n'), drop the partial first line so
# the consumer sees only whole JSONL records. Bash's command substitution strips
# trailing newlines, so the prev-byte check uses string emptiness as the signal.
#
# `|| true` on each `tail | head` pipeline: head closes the pipe after reading
# `size` bytes, which makes `tail` write into a closed pipe and exit 141 via
# SIGPIPE. Under `set -euo pipefail`, that 141 would propagate and abort the
# whole script. The output we care about (head's stdout) is already complete by
# the time tail dies, so suppressing the pipe-fail exit code is safe.
read_window() {
  local start="$1" size="$2"
  if [ "$start" -le 0 ]; then
    head -c "$size" "$transcript_path" || true
    return 0
  fi
  local prev
  prev=$(tail -c +"$start" "$transcript_path" 2>/dev/null | head -c 1 || true)
  if [ -z "$prev" ]; then
    tail -c +$((start + 1)) "$transcript_path" | head -c "$size" || true
  else
    tail -c +$((start + 1)) "$transcript_path" | head -c "$size" | tail -n +2 || true
  fi
}

# Walk the new window in chunks. For each chunk with hits, write a regex-only
# fallback raw file synchronously and leave the slice on disk for enrich.
cur=$stored_offset
while [ "$cur" -lt "$new_offset" ]; do
  chunk_start=$cur
  chunk_end=$((cur + MAX_CHUNK))
  [ "$chunk_end" -gt "$new_offset" ] && chunk_end=$new_offset
  cur=$chunk_end

  slice_start=$((chunk_start - LOOKBACK))
  [ "$slice_start" -lt 0 ] && slice_start=0
  slice_size=$((chunk_end - slice_start))

  slice_file="$STATE_DIR/slice-${session_id}-$(printf '%012d' "$chunk_end")-$$.jsonl"

  # Slice (with lookback) for later enrichment.
  read_window "$slice_start" "$slice_size" > "$slice_file"

  # Per-chunk regex screen — restricted to the chunk's OWN bytes (no lookback).
  # Hits inside the lookback would otherwise be double-counted across chunks.
  chunk_size=$((chunk_end - chunk_start))
  chunk_hits=$(read_window "$chunk_start" "$chunk_size" \
    | jq -r 'select(.type=="assistant") | .message.content // empty' 2>/dev/null \
    | grep -iE "$PUNT_PHRASES" || true)

  if [ -z "$chunk_hits" ]; then
    rm -f "$slice_file"
    continue
  fi

  out_file=".claude/punts/raw/${session_id}-$(printf '%012d' "$chunk_end")-$$.json"

  # Regex-only fallback. session_id embedded so punts-enrich.sh doesn't have
  # to reverse-engineer it from the filename (UUIDs contain dashes).
  jq -n --arg sid "$session_id" --arg hits "$chunk_hits" \
    '{session_id: $sid, regex_hits: $hits, fallback: "regex-only"}' > "$out_file.tmp"
  mv "$out_file.tmp" "$out_file"
done

exit 0
