#!/bin/bash
#
# sync-config.sh - Sync Claude Code config files from shared submodule to target repo
#
# Usage: ./shared/scripts/sync-config.sh [--force] [--dry-run]
#
# Safety: Compares the old submodule version of each file with the current target.
# If they differ, the target has local modifications and is skipped (unless --force).
#
# Repo detection: Reads package.json "name" field to determine coinbridge-api or coinbridge-frontend.
#
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Path resolution
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHARED_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SHARED_ROOT/.." && pwd)"

# Parse arguments
FORCE=false
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
        --dry-run) DRY_RUN=true ;;
        *)
            echo -e "${RED}Error: Unknown option: $arg${NC}"
            echo "Usage: $0 [--force] [--dry-run]"
            exit 1
            ;;
    esac
done

# Detect repo type from package.json
PACKAGE_JSON="$REPO_ROOT/package.json"
if [[ ! -f "$PACKAGE_JSON" ]]; then
    echo -e "${RED}Error: package.json not found at $PACKAGE_JSON${NC}"
    exit 1
fi

REPO_NAME=$(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "$PACKAGE_JSON" | head -1 | sed 's/.*"name"[[:space:]]*:[[:space:]]*"//;s/"//')
if [[ -z "$REPO_NAME" ]]; then
    echo -e "${RED}Error: Could not read name from package.json${NC}"
    exit 1
fi

if echo "$REPO_NAME" | grep -qi "api"; then
    CONFIG_DIR="$SHARED_ROOT/claude-config-instructions/coinbridge-api"
elif echo "$REPO_NAME" | grep -qi "frontend"; then
    CONFIG_DIR="$SHARED_ROOT/claude-config-instructions/coinbridge-frontend"
else
    echo -e "${RED}Error: Cannot determine repo type from package.json name: $REPO_NAME${NC}"
    echo "Expected name to contain 'api' or 'frontend'"
    exit 1
fi

if [[ ! -d "$CONFIG_DIR" ]]; then
    echo -e "${RED}Error: Config directory not found: $CONFIG_DIR${NC}"
    exit 1
fi

# Determine old submodule commit (what parent repo has recorded)
OLD_COMMIT=$(git -C "$REPO_ROOT" ls-tree HEAD shared 2>/dev/null | awk '{print $3}')
CURRENT_COMMIT=$(git -C "$SHARED_ROOT" rev-parse HEAD 2>/dev/null)

if [[ -z "$OLD_COMMIT" ]]; then
    echo -e "${YELLOW}Warning: Could not determine old submodule commit (first-time setup?)${NC}"
    echo -e "Proceeding with sync (all files treated as new)..."
    OLD_COMMIT=""
elif [[ "$OLD_COMMIT" == "$CURRENT_COMMIT" ]]; then
    if [[ "$FORCE" == false ]]; then
        echo -e "${GREEN}Submodule commit unchanged. Nothing to sync.${NC}"
        exit 0
    fi
    echo -e "${YELLOW}Submodule commit unchanged, but --force specified. Proceeding...${NC}"
fi

echo -e "${CYAN}Syncing config from: ${CONFIG_DIR##*/}${NC}"
echo -e "  Old commit: ${OLD_COMMIT:0:8}..."
echo -e "  New commit: ${CURRENT_COMMIT:0:8}..."
if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}  (dry-run mode — no files will be modified)${NC}"
fi
echo ""

# Counters
CREATED=0
UPDATED=0
SKIPPED=0
UNCHANGED=0

# Iterate over all files in the config directory
while IFS= read -r -d '' SOURCE_FILE; do
    # Get relative path within the config directory
    REL_PATH="${SOURCE_FILE#$CONFIG_DIR/}"
    TARGET_FILE="$REPO_ROOT/$REL_PATH"

    # Get the relative path within the shared repo (for git show)
    SHARED_REL_PATH="${SOURCE_FILE#$SHARED_ROOT/}"

    # Determine action
    if [[ ! -f "$TARGET_FILE" ]]; then
        # Target doesn't exist — create it
        echo -e "  ${GREEN}CREATE${NC} $REL_PATH"
        if [[ "$DRY_RUN" == false ]]; then
            mkdir -p "$(dirname "$TARGET_FILE")"
            cp "$SOURCE_FILE" "$TARGET_FILE"
        fi
        CREATED=$((CREATED + 1))
    else
        # Target exists — check if it's safe to update
        # First check if the new version is same as target (no change needed)
        if diff -q "$SOURCE_FILE" "$TARGET_FILE" >/dev/null 2>&1; then
            UNCHANGED=$((UNCHANGED + 1))
            continue
        fi

        # File differs from new version — check against old version
        SAFE_TO_UPDATE=false
        OLD_EXISTS=false
        if [[ -z "$OLD_COMMIT" ]]; then
            # No old commit info (first-time setup) — treat as conflict
            SAFE_TO_UPDATE=false
        elif git -C "$SHARED_ROOT" cat-file -e "$OLD_COMMIT:$SHARED_REL_PATH" 2>/dev/null; then
            OLD_EXISTS=true
            # Compare old version with current target (use git show directly to preserve exact content)
            if diff -q <(git -C "$SHARED_ROOT" show "$OLD_COMMIT:$SHARED_REL_PATH") "$TARGET_FILE" >/dev/null 2>&1; then
                SAFE_TO_UPDATE=true
            fi
        fi

        if [[ "$SAFE_TO_UPDATE" == true ]] || [[ "$FORCE" == true ]]; then
            if [[ "$FORCE" == true ]] && [[ "$SAFE_TO_UPDATE" == false ]]; then
                echo -e "  ${YELLOW}FORCE${NC}  $REL_PATH (local changes overwritten)"
            else
                echo -e "  ${GREEN}UPDATE${NC} $REL_PATH"
            fi
            if [[ "$DRY_RUN" == false ]]; then
                mkdir -p "$(dirname "$TARGET_FILE")"
                cp "$SOURCE_FILE" "$TARGET_FILE"
            fi
            UPDATED=$((UPDATED + 1))
        else
            if [[ -z "$OLD_COMMIT" ]] || [[ "$OLD_EXISTS" == false ]]; then
                echo -e "  ${YELLOW}SKIP${NC}   $REL_PATH (conflict: file exists locally, new in shared)"
            else
                echo -e "  ${YELLOW}SKIP${NC}   $REL_PATH (local changes detected)"
            fi
            SKIPPED=$((SKIPPED + 1))
        fi
    fi
done < <(find "$CONFIG_DIR" -type f -print0)

# Summary
echo ""
echo -e "${CYAN}Summary:${NC}"
[[ $CREATED -gt 0 ]] && echo -e "  ${GREEN}Created:${NC}   $CREATED"
[[ $UPDATED -gt 0 ]] && echo -e "  ${GREEN}Updated:${NC}   $UPDATED"
[[ $UNCHANGED -gt 0 ]] && echo -e "  Unchanged: $UNCHANGED"
[[ $SKIPPED -gt 0 ]] && echo -e "  ${YELLOW}Skipped:${NC}   $SKIPPED (use --force to overwrite)"

if [[ $CREATED -eq 0 ]] && [[ $UPDATED -eq 0 ]] && [[ $SKIPPED -eq 0 ]]; then
    echo -e "  ${GREEN}All files up to date.${NC}"
fi
