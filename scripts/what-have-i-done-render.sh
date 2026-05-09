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
#   - On <today>: project is shown with "- (no git activity in window)".
#   - On prior days: project is omitted entirely.
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
  if [ "$date" = "$TODAY" ]; then
    heading="Today"
  elif [ "$date" = "$YESTERDAY" ]; then
    heading="Yesterday"
  else
    heading="$(date -j -f %Y-%m-%d "$date" +%A)"
  fi

  printf '\n## %s (%s)\n' "$heading" "$date"

  is_today=0
  [ "$date" = "$TODAY" ] && is_today=1

  while IFS= read -r project; do
    [ -z "$project" ] && continue

    bullets_json=$(printf '%s' "$INPUT" \
      | jq -c --arg d "$date" --arg p "$project" '.[$d][$p]')
    bullet_count=$(printf '%s' "$bullets_json" | jq 'length')

    if [ "$bullet_count" -eq 0 ]; then
      if [ "$is_today" -eq 1 ]; then
        printf '\n**%s**\n' "$project"
        printf -- '- (no git activity in window)\n'
      fi
      continue
    fi

    printf '\n**%s**\n' "$project"
    printf '%s' "$bullets_json" | jq -r '.[]' | while IFS= read -r bullet; do
      printf -- '- %s\n' "$bullet"
    done
  done < <(printf '%s' "$INPUT" | jq -r --arg d "$date" '.[$d] | keys_unsorted[]')
done
