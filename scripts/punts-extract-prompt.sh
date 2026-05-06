#!/usr/bin/env bash
# Build the prompt fed to `claude -p` for extracting punt evidence from a
# slice of a session transcript. Pure stdout — no file I/O. Called by
# punts-detect.sh once per chunk that contains regex hits.
#
# Args:
#   $1  slice_path   Path to the per-chunk JSONL slice (NOT the full
#                    transcript — see punts-detect.sh chunking logic).
#   $2  session_id   Session UUID.
#   $3  regex_hits   Newline-separated lines from this chunk that matched
#                    the regex screen.
set -euo pipefail

slice_path="$1"
session_id="$2"
regex_hits="$3"

ended_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"

cat <<PROMPT
You are analyzing a Claude Code session transcript to extract "punts" — issues
the assistant noticed but explicitly chose not to fix because they were
pre-existing, out of scope, or unrelated to the current change.

Read the transcript slice at: $slice_path

Note: this file is a byte-range slice from a longer JSONL session transcript —
bytes before the slice are intentionally not visible. Limit evidence_quote and
context_quote to lines that are actually present in this slice; do not infer
content from outside it.

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
  session_ended_at:  $ended_at  (timestamp of when this Stop hook fired; for
                                 backlog drains this is "now", not the wall-
                                 clock time the underlying messages were
                                 originally written)
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
