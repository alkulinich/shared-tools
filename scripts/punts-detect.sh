#!/usr/bin/env bash
# Stop hook for Claude Code sessions. When the assistant declines to fix an
# issue (calling it pre-existing, out of scope, etc., or marking it [PUNT]:),
# capture evidence to .claude/punts/raw/<session>-<chunk_end>-<pid>.json for
# later triage.
#
# Inputs (stdin JSON):
#   .transcript_path  Absolute path to the session's JSONL transcript.
#   .session_id       Stable UUID identifying the session.
#
# State:
#   .claude/punts/state/<session_id>.offset
#     Last byte offset of the transcript that has already been screened.
#   .claude/punts/state/slice-<session_id>-<chunk_end>-<pid>.jsonl
#     Per-chunk byte slice of the new window (with a small lookback). Handed to
#     `claude -p` instead of the full transcript so the subagent's input stays
#     bounded; deleted by the backgrounded subshell after enrichment.
#
# Outputs:
#   .claude/punts/raw/<session_id>-<chunk_end>-<pid>.json
#     One per chunk with regex hits. Synchronous write is the regex-only
#     fallback; the backgrounded `claude -p` overwrites with structured
#     evidence on success (and leaves the fallback intact on failure).
#
# Behavior:
#   1. Compute byte window = transcript size minus stored offset (with
#      shrinkage detection for compaction).
#   2. Advance the stored offset durably before any chunking work — these bytes
#      are screened, regardless of subagent fate.
#   3. Quick whole-window regex screen as a Bloom filter; bail early if empty.
#   4. Split the window into chunks of at most $PUNT_MAX_CHUNK bytes. Each
#      chunk gets a lookback prefix so the subagent can still emit the
#      "1-2 surrounding lines" context quote.
#   5. Per chunk: extract the slice, regex-screen it, write a synchronous
#      regex-only fallback raw file, queue for subagent enrichment.
#   6. Background subshell runs `claude -p` per queued chunk sequentially
#      (UI is unblocked because of `& disown`; serial within the subshell
#      avoids API rate-limit storms on big backlogs).
#
# Tunables (env):
#   PUNT_MAX_CHUNK   Max bytes per chunk handed to one subagent (default 256K).
#   PUNT_LOOKBACK    Bytes of pre-chunk context included in each slice (default 4K).
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

# Advance offset regardless of hits — these bytes have been screened and we do
# not want to re-screen them on the next Stop fire.
printf '%s\n' "$new_offset" > "$state_file.tmp"
mv "$state_file.tmp" "$state_file"

# No hits anywhere in the new window → state advanced, nothing else to do.
[ -z "$window_hits" ] && exit 0

mkdir -p .claude/punts/raw

# Chunk parameters (env-overridable for tests / power users).
MAX_CHUNK=${PUNT_MAX_CHUNK:-$((256 * 1024))}
LOOKBACK=${PUNT_LOOKBACK:-$((4 * 1024))}

CLAUDE_BIN="$(command -v claude || true)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Read bytes [start, start+size) from the transcript. If `start` lands mid-line
# (i.e., the byte at `start - 1` is not '\n'), drop the partial first line so
# the consumer sees only whole JSONL records. Bash's command substitution strips
# trailing newlines, so the prev-byte check uses string emptiness as the signal.
read_window() {
  local start="$1" size="$2"
  if [ "$start" -le 0 ]; then
    head -c "$size" "$transcript_path"
    return 0
  fi
  local prev
  prev=$(tail -c +"$start" "$transcript_path" 2>/dev/null | head -c 1 || true)
  if [ -z "$prev" ]; then
    # Byte at start-1 was '\n' (or beyond EOF) → start sits on a line boundary.
    tail -c +$((start + 1)) "$transcript_path" | head -c "$size"
  else
    tail -c +$((start + 1)) "$transcript_path" | head -c "$size" | tail -n +2
  fi
}

# Build the chunk worklist. Each chunk yields at most MAX_CHUNK bytes from the
# new window; lookback widens the slice on the leading edge for context.
chunk_slice_files=()
chunk_out_files=()
chunk_hits_payloads=()

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

  # Slice (with lookback) for the subagent. read_window auto-trims the
  # likely-partial leading line when slice_start lands mid-line.
  read_window "$slice_start" "$slice_size" > "$slice_file"

  # Per-chunk regex screen — restricted to the chunk's OWN bytes (no lookback).
  # Otherwise hits inside the lookback would be double-counted by both this
  # chunk and the previous one.
  chunk_size=$((chunk_end - chunk_start))
  chunk_hits=$(read_window "$chunk_start" "$chunk_size" \
    | jq -r 'select(.type=="assistant") | .message.content // empty' 2>/dev/null \
    | grep -iE "$PUNT_PHRASES" || true)

  if [ -z "$chunk_hits" ]; then
    rm -f "$slice_file"
    continue
  fi

  out_file=".claude/punts/raw/${session_id}-$(printf '%012d' "$chunk_end")-$$.json"

  # Synchronous regex-only fallback per chunk — guarantees an artifact even if
  # the subagent never gets a chance to enrich it.
  jq -n --arg hits "$chunk_hits" '{regex_hits: $hits, fallback: "regex-only"}' > "$out_file.tmp"
  mv "$out_file.tmp" "$out_file"

  chunk_slice_files+=("$slice_file")
  chunk_out_files+=("$out_file")
  chunk_hits_payloads+=("$chunk_hits")
done

# Nothing to enrich — either no claude binary or all chunks were false starts.
if [ -z "$CLAUDE_BIN" ] || [ "${#chunk_slice_files[@]}" -eq 0 ]; then
  # Slice files for chunks that did have hits still exist if claude is missing.
  # Clean them up here since no subagent will read them.
  if [ -z "$CLAUDE_BIN" ]; then
    for slice_file in "${chunk_slice_files[@]:-}"; do
      [ -n "$slice_file" ] && rm -f "$slice_file"
    done
  fi
  exit 0
fi

# Background enrichment. Sequential within the subshell — serial avoids
# API rate-limit storms when draining a large backlog (cost is fine; 429s
# would make every chunk fail simultaneously).
(
  for i in "${!chunk_slice_files[@]}"; do
    slice_file="${chunk_slice_files[$i]}"
    out_file="${chunk_out_files[$i]}"
    chunk_hits="${chunk_hits_payloads[$i]}"

    prompt="$(bash "$SCRIPT_DIR/punts-extract-prompt.sh" "$slice_file" "$session_id" "$chunk_hits")"
    if "$CLAUDE_BIN" -p "$prompt" --output-format json --max-turns 1 \
         > "$out_file.tmp" 2>/dev/null; then
      mv "$out_file.tmp" "$out_file"
    else
      rm -f "$out_file.tmp"
    fi
    rm -f "$slice_file"
  done
) &
disown
exit 0
