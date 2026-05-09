#!/usr/bin/env bash
#
# what-have-i-done-discover.sh — list recently-touched Claude project dirs,
# resolved to their real cwds.
#
# Usage:  discover.sh [N]              # N = days, default 3
# Env:    WHID_PROJECTS_DIR            # override projects dir (for tests)
# Stdout: one line per project, tab-separated:
#           <real_cwd>\t<claude_project_dir>
#
# Behaviour:
#   - find dirs under PROJECTS_DIR with mtime within last N days.
#   - skip dirs whose basename starts with "-private-var-".
#   - resolve real_cwd from the most recent *.jsonl's first line (.cwd).
#   - skip if .cwd is missing or the path no longer exists.
#   - dedupe by real_cwd (first occurrence wins, alphabetical order).
#
set -euo pipefail

N="${1:-3}"
PROJECTS_DIR="${WHID_PROJECTS_DIR:-$HOME/.claude/projects}"

# rtk proxy if available.
if command -v rtk &>/dev/null; then
  rtk() { command rtk "$@"; }
else
  rtk() { "$@"; }
fi

[ -d "$PROJECTS_DIR" ] || exit 0

# Sort the find output for deterministic dedupe order, then dedupe by the
# first tab-separated column (real_cwd) via awk — bash 3.2 friendly (no
# associative arrays).
while IFS= read -r dir; do
  [ -z "$dir" ] && continue

  base=$(basename "$dir")
  case "$base" in
    -private-var-*) continue ;;
  esac

  # Most recent JSONL inside this dir.
  most_recent_jsonl=$(ls -1t "$dir"/*.jsonl 2>/dev/null | head -n1 || true)
  [ -z "$most_recent_jsonl" ] && continue

  real_cwd=$(head -n1 "$most_recent_jsonl" | rtk jq -r '.cwd // empty' 2>/dev/null || true)
  if [ -z "$real_cwd" ]; then
    printf 'discover: skipped %s (no cwd)\n' "$dir" >&2
    continue
  fi

  [ ! -d "$real_cwd" ] && continue

  printf '%s\t%s\n' "$real_cwd" "$dir"
done < <(find "$PROJECTS_DIR" -mindepth 1 -maxdepth 1 -type d -mtime -"$N" 2>/dev/null | sort) \
  | awk -F'\t' '!seen[$1]++'
