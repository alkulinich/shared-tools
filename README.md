# rulez-claudeset

Shared Claude Code commands, permissions, and status line for GitHub Flow workflow.

## Install (global)

```bash
git clone https://github.com/alkulinich/rulez-claudeset ~/.claude/skills/rulez-claudeset
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
git submodule add https://github.com/alkulinich/rulez-claudeset rulez-claudeset
./rulez-claudeset/bin/setup-per-project.sh
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
| `/rulez:punts-triage` | Walk captured punt evidence and promote worthy items to `.claude/punts/*.md` |
| `/rulez:punts-enrich` | Back-fill structured rows for regex-only punt evidence (batch) |
| `/rulez:what-have-i-done [N]` | Cross-project rollup: last N calendar days (default 3) of HANDOFF.md + commit subjects across every recently-touched Claude project. |
| `/rulez:new-project:*` | New project setup workflow (7 steps) |
| `/rulez:update-claudeset` | Pull latest version and re-run setup |

## Punts

A "punt" is something you noticed but chose not to fix in the current change — pre-existing, out of scope, or a follow-up. Flag it inline as:

```
[PUNT]: <one-line description of what you saw and where>
```

A Stop hook (`scripts/punts-detect.sh`) screens each session's transcript for these phrases (and a few softer variants like "pre-existing", "out of scope") and writes regex-only evidence to `.claude/punts/raw/*.json` along with a transcript slice in `.claude/punts/state/`. Detection is synchronous and millisecond-cheap — no subagent runs in the hook.

When you're ready, run `/rulez:punts-triage`. It enriches any regex-only rows via parallel subagents, then walks each structured row interactively (APPROVE / REJECT / SKIP / MERGE) and promotes approved ones to `.claude/punts/<slug>.md` (one issue per file, git-tracked). For batch back-fills outside triage, `/rulez:punts-enrich` runs the enrichment alone.

## What Have I Done

`/rulez:what-have-i-done [N]` reads the last N calendar days (default 3) across every Claude project you've touched and prints a grouped-by-project rollup of HANDOFF.md commits + recent commit subjects. One Agent per project runs in parallel, then a pure renderer formats the result.

The same markdown lands in `~/.claude/what-have-i-done/<today>.md` so you can scroll back through prior days. Re-running on the same day overwrites that day's file (later runs catch fresher commits). Days with no activity for a given project are omitted on prior dates and shown as `(no git activity in window)` for today.

## Utility Scripts

| Script | Description | Usage |
|--------|-------------|-------|
| `scripts/session-time.sh` | Today's active session time (heartbeat-based) | Called by statusline automatically |
| `scripts/session-stats.sh` | Day-by-day session time history | `bash ~/.claude/skills/rulez-claudeset/scripts/session-stats.sh` |
| `scripts/context-meter.sh` | Context window usage bar (ANSI) | Called by statusline automatically |
| `scripts/statusline.sh` | Status line renderer (PID, model, time, context, branch) | Configured in settings.json |
| `scripts/punts-detect.sh` | Stop hook — regex-screens session transcripts, writes raw punt evidence | Auto-invoked on session Stop |
| `scripts/punts-enrich.sh` | Promotes regex-only raw rows to structured rows via `claude -p` | `bash ~/.claude/skills/rulez-claudeset/scripts/punts-enrich.sh` |
| `scripts/punts-extract-prompt.sh` | Builds the extraction prompt fed to the enrichment subagent | Called by triage / enrich |
| `scripts/what-have-i-done-discover.sh` | Lists recently-touched Claude project dirs, resolved to real cwds | Called by `/rulez:what-have-i-done` |
| `scripts/what-have-i-done-render.sh` | Pure stdin→markdown formatter for the rollup | Called by `/rulez:what-have-i-done` |

## Requirements

- `jq` for settings merge
- `gh` CLI for GitHub operations
