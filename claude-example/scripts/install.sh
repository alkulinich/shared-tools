#!/bin/bash
# Installs Claude Code commands, permissions, and status line from the shared
# submodule into the host repo.  Merges shared permissions into any existing
# .claude/settings.json without destroying user customizations.
#
# Usage (from repo root):
#   ./shared-tools/claude-example/scripts/install.sh [--force] [--dry-run]
#
# The script auto-detects the submodule path from its own location, so the
# submodule can be cloned under any name (shared/, tools/, shared-tools/, etc.)
#
# Flags:
#   --force    Overwrite git-workflow.md even if it already exists
#   --dry-run  Show what would be done without writing any files

set -euo pipefail

# ── Parse flags ──────────────────────────────────────────────────────────────
FORCE=false
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --force)   FORCE=true ;;
    --dry-run) DRY_RUN=true ;;
    *)         echo "Unknown option: $arg"; exit 1 ;;
  esac
done

# ── Derive paths ─────────────────────────────────────────────────────────────
# Resolve all paths through pwd -P to canonicalize symlinks (e.g. /tmp → /private/tmp on macOS)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SHARED_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# REPO_ROOT = the host repo's git root (works regardless of nesting depth)
REPO_ROOT="$(cd "$SHARED_ROOT" && git rev-parse --show-toplevel)"

# SUBMODULE_REL = relative path from repo root to SHARED_ROOT
# e.g. "shared-tools/claude-example" or just "shared"
SUBMODULE_REL="${SHARED_ROOT#"$REPO_ROOT"/}"

# SUBMODULE_GIT_ROOT = the submodule's own git root (for git -C operations)
# In a real submodule this returns the submodule root; otherwise same as REPO_ROOT
SUBMODULE_GIT_ROOT="$(cd "$SHARED_ROOT" && git rev-parse --show-toplevel)"
SUBMODULE_GIT_REL="${SUBMODULE_GIT_ROOT#"$REPO_ROOT"/}"
# If SUBMODULE_GIT_REL equals REPO_ROOT (not a submodule), derive from SUBMODULE_REL
if [ "$SUBMODULE_GIT_REL" = "$SUBMODULE_GIT_ROOT" ] || [ "$SUBMODULE_GIT_REL" = "$REPO_ROOT" ]; then
  # Use the first path component of SUBMODULE_REL as the git root
  SUBMODULE_GIT_REL="${SUBMODULE_REL%%/*}"
  # If no slash (flat structure), git root is the same as SUBMODULE_REL
  if [ "$SUBMODULE_GIT_REL" = "$SUBMODULE_REL" ]; then
    SUBMODULE_GIT_REL="$SUBMODULE_REL"
  fi
fi

echo "Detected paths:"
echo "  Repo root:      $REPO_ROOT"
echo "  Shared content:  $SUBMODULE_REL"
echo "  Submodule root:  $SUBMODULE_GIT_REL"
echo ""

# ── Validate prerequisites ───────────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed."
  echo "  brew install jq   # macOS"
  echo "  apt install jq    # Debian/Ubuntu"
  exit 1
fi

if [ ! -f "$SHARED_ROOT/.claude/settings.json" ]; then
  echo "Error: $SHARED_ROOT/.claude/settings.json not found"
  exit 1
fi

if [ ! -d "$SHARED_ROOT/.claude/commands" ]; then
  echo "Error: $SHARED_ROOT/.claude/commands/ not found"
  exit 1
fi

# ── Helper: write or dry-run ─────────────────────────────────────────────────
write_file() {
  local dest="$1"
  local content="$2"
  if $DRY_RUN; then
    echo "  [dry-run] would write: $dest"
  else
    mkdir -p "$(dirname "$dest")"
    printf '%s' "$content" > "$dest"
  fi
}

copy_file() {
  local src="$1"
  local dest="$2"
  if $DRY_RUN; then
    echo "  [dry-run] would copy: $src -> $dest"
  else
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
  fi
}

# ── 1. Install commands ─────────────────────────────────────────────────────
echo "Installing commands..."
SOURCE_DIR="$SHARED_ROOT/.claude/commands"
cmd_count=0

while IFS= read -r file; do
  rel="${file#"$SOURCE_DIR"/}"
  dest="$REPO_ROOT/.claude/commands/$rel"
  # Rewrite ./scripts/ references to point at the submodule's scripts
  content="$(sed "s|\\./scripts/|${SUBMODULE_REL}/scripts/|g" "$file")"
  write_file "$dest" "$content"
  cmd_count=$((cmd_count + 1))
done < <(find "$SOURCE_DIR" -name '*.md' -type f)

echo "  $cmd_count command(s) installed to .claude/commands/"

# ── 2. Install settings.json (merge) ────────────────────────────────────────
echo "Installing settings..."

TEMPLATE="$SHARED_ROOT/.claude/settings.json"
EXISTING="$REPO_ROOT/.claude/settings.json"

# Rewrite paths in the template:
#   "shared/scripts/" → "<submodule_rel>/scripts/"  (permissions & statusLine)
#   "shared/scripts/"  with ./ prefix too
#   "git -C shared "   → "git -C <submodule_git_rel> "  (submodule git root)
rewritten_template="$(sed \
  -e "s|shared/scripts/|${SUBMODULE_REL}/scripts/|g" \
  -e "s|git -C shared |git -C ${SUBMODULE_GIT_REL} |g" \
  "$TEMPLATE")"

if [ ! -f "$EXISTING" ]; then
  # Fresh install — write rewritten template directly
  write_file "$EXISTING" "$rewritten_template"
  echo "  Created .claude/settings.json (fresh install)"
else
  # Merge: union permissions, replace statusLine, preserve everything else
  if $DRY_RUN; then
    echo "  [dry-run] would merge into existing .claude/settings.json"
  else
    merged="$(jq -s '
      .[0] as $existing | .[1] as $new |
      $existing * {
        permissions: {
          allow: (
            (($existing.permissions.allow // []) + ($new.permissions.allow // []))
            | unique
          )
        },
        statusLine: $new.statusLine
      }
    ' "$EXISTING" <(printf '%s' "$rewritten_template"))"
    printf '%s\n' "$merged" > "$EXISTING"
    echo "  Merged permissions and updated statusLine in .claude/settings.json"
  fi
fi

# ── 3. Copy git-workflow.md ──────────────────────────────────────────────────
WORKFLOW_SRC="$SHARED_ROOT/git-workflow.md"
WORKFLOW_DST="$REPO_ROOT/git-workflow.md"

if [ -f "$WORKFLOW_SRC" ]; then
  if [ ! -f "$WORKFLOW_DST" ] || $FORCE; then
    copy_file "$WORKFLOW_SRC" "$WORKFLOW_DST"
    echo "  Installed git-workflow.md"
  else
    echo "  Skipped git-workflow.md (already exists, use --force to overwrite)"
  fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
if $DRY_RUN; then
  echo "Dry run complete. No files were modified."
else
  echo "Install complete!"
  echo "  Submodule path: $SUBMODULE_REL"
  echo "  Commands:       $cmd_count"
  echo "  Settings:       .claude/settings.json"
fi
