# rulez-claudeset

Shared Claude Code commands, permissions, and status line for GitHub Flow workflow.

## Install (global)

```bash
git clone <repo-url> ~/.claude/skills/rulez-claudeset
cd ~/.claude/skills/rulez-claudeset && ./bin/setup
```

This will:
1. Symlink commands to `~/.claude/commands/rulez/` (available as `/rulez:start-issue`, etc.)
2. Merge permissions into `~/.claude/settings.json`
3. Install a SessionStart hook for auto-updates

Auto-updates run in the background on every Claude Code session (1-hour throttle, ff-only pull).

## Install (per-project)

Add as a submodule and run the per-project installer:

```bash
git submodule add <repo-url> rulez-claudeset
./rulez-claudeset/install.sh
```

This copies commands into the repo's `.claude/` with paths rewritten for the submodule location.

## Commands

| Command | Description |
|---------|-------------|
| `/rulez:brainstorm` | Brainstorm before coding |
| `/rulez:add-issue` | Create a GitHub issue |
| `/rulez:start-issue 4` | Fetch issue, update main, create feature branch |
| `/rulez:create-pr` | Analyze changes, create commit, push, open PR |
| `/rulez:test-pr 5` | Checkout PR, build Docker, run tests |
| `/rulez:push-fixes` | Add fixes to current branch and push |
| `/rulez:merge-pr 5` | Merge PR and cleanup branches |
| `/rulez:handoff` | Write HANDOFF.md for next agent |
| `/rulez:dispatch-subagent` | Launch a subagent for a task |
| `/rulez:simple-script` | Write a minimal shell script |
| `/rulez:new-project:*` | New project setup workflow (7 steps) |

## Utility Scripts

| Script | Description | Usage |
|--------|-------------|-------|
| `scripts/session-time.sh` | Today's active session time (heartbeat-based) | Called by statusline automatically |
| `scripts/session-stats.sh` | Day-by-day session time history | `bash ~/.claude/skills/rulez-claudeset/scripts/session-stats.sh` |
| `scripts/context-meter.sh` | Context window usage bar (ANSI) | Called by statusline automatically |
| `scripts/statusline.sh` | Status line renderer (PID, model, time, context, branch) | Configured in settings.json |

## Requirements

- `jq` for settings merge
- `gh` CLI for GitHub operations
