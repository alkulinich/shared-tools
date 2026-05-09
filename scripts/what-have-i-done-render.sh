#!/usr/bin/env bash
#
# what-have-i-done-render.sh — pure stdin→stdout markdown formatter.
#
# Usage: render.sh <today_YYYY-MM-DD>
# Stdin: JSON of shape
#   { "<YYYY-MM-DD>": { "<project_basename>": ["bullet", ...] }, ... }
# Stdout: rendered markdown body.
#
# Heading rules:
#   - <today>           → "Today"
#   - <today minus 1>   → "Yesterday"
#   - other dates       → weekday name (e.g. "Thursday")
#
# Empty-project rules:
#   - Projects with no bullets are omitted on every date (today included).
#   - Date headings are skipped entirely when no project under them has bullets.
#
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <today_YYYY-MM-DD>" >&2
  exit 2
fi

TODAY="$1"
INPUT="$(cat)"

# Compute yesterday in YYYY-MM-DD using BSD date.
YESTERDAY="$(date -j -f %Y-%m-%d -v-1d "$TODAY" +%Y-%m-%d)"

# Sorted descending: most recent date first.
DATES=$(printf '%s' "$INPUT" | jq -r 'keys_unsorted[]' | sort -r)

printf "# What I've done — generated %s\n" "$TODAY"

for date in $DATES; do
  # Skip the date entirely if no project under it has bullets — applies to
  # today as well now (no more "(no git activity in window)" markers).
  has_any=$(printf '%s' "$INPUT" \
    | jq --arg d "$date" '[.[$d] | values[] | select(length > 0)] | length')
  [ "$has_any" -eq 0 ] && continue

  if [ "$date" = "$TODAY" ]; then
    heading="Today"
  elif [ "$date" = "$YESTERDAY" ]; then
    heading="Yesterday"
  else
    heading="$(date -j -f %Y-%m-%d "$date" +%A)"
  fi

  printf '\n## %s (%s)\n' "$heading" "$date"

  while IFS= read -r project; do
    [ -z "$project" ] && continue

    bullets_json=$(printf '%s' "$INPUT" \
      | jq -c --arg d "$date" --arg p "$project" '.[$d][$p]')
    bullet_count=$(printf '%s' "$bullets_json" | jq 'length')

    [ "$bullet_count" -eq 0 ] && continue

    printf '\n**%s**\n' "$project"
    # Index-based access so bullets containing literal newlines (used for
    # nested sub-bullets, e.g. "Worked on X:\n  - PR #1") stay intact —
    # `jq -r '.[]' | while read` would split each newline into its own
    # iteration and lose the leading "- " on continuation lines.
    bi=0
    while [ "$bi" -lt "$bullet_count" ]; do
      bullet=$(printf '%s' "$bullets_json" | jq -r ".[$bi]")
      printf -- '- %s\n' "$bullet"
      bi=$((bi + 1))
    done
  done < <(printf '%s' "$INPUT" | jq -r --arg d "$date" '.[$d] | keys_unsorted[]')
done
