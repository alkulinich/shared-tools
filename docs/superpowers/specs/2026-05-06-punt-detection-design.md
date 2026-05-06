# Punt Detection & Triage — Design (v1.2.0)

Status: draft, pending user approval.
Date: 2026-05-06.

## Problem

Claude Code routinely identifies issues in the codebase that are *outside the
scope of the current task* and declines to fix them ("pre-existing", "out of
scope", "unrelated to this change"). This behavior is deliberate — it avoids
scope creep and prevents stepping on parallel sessions on the same branch — but
the side effect is that legitimate findings hit the floor with no audit trail.
Over time, real issues accumulate as silent observations that nobody captures.

Goal: capture every genuine punt with enough evidence to triage later, without
dampening Claude's healthy scope discipline.

## Approach

Two-stage detection at session end, single human-triage step on demand:

1. **Stop hook** runs at session end. It regex-screens the transcript for
   suspicious phrases plus an explicit `[PUNT]:` marker. If at least one match
   is found, it forks a backgrounded `claude -p` subagent to read the
   transcript and emit structured evidence rows. The hook returns immediately
   so the UI is not blocked. Output is written to
   `.claude/punts/raw/<session-uuid>.json`.

2. **`/rulez:punts-triage`** slash command, run on demand by the user, walks
   accumulated raw evidence and promotes each approved entry to a curated
   `.claude/punts/<slug>.md` file (one issue per file). Rejected entries are
   discarded; skipped entries persist for the next triage pass.

3. **Soft `[PUNT]:` marker convention** — `RULEZ.md` instructs Claude to flag
   out-of-scope decisions as `[PUNT]: <reason>` on their own line. This is a
   belt-and-suspenders signal: the regex catches `[PUNT]:` markers explicitly
   *and* the soft phrasing list catches what Claude doesn't self-tag. The
   subagent treats marker-derived evidence as `confidence: high` and
   regex-derived as `medium` or `low`.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ Session ends → Stop hook fires                                   │
│   reads stdin JSON → transcript_path, session_id                 │
│                                                                  │
│   1) Regex pre-screen on transcript                              │
│      Match either:                                               │
│        a) [PUNT]: marker line, or                                │
│        b) soft phrase set (pre-existing, out of scope, etc.)     │
│      → 0 hits: exit 0                                            │
│      → ≥1 hit: continue                                          │
│                                                                  │
│   2) Background-fork triage subagent (nohup claude -p ... &)     │
│      • Reads transcript + regex hits                             │
│      • Emits JSON array of evidence rows                         │
│      • Writes .claude/punts/raw/<session-uuid>.json              │
│      • Hook detaches and returns immediately                     │
│                                                                  │
│   3) Hook exits clean (subagent finishes asynchronously)         │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ Later: user runs /rulez:punts-triage                             │
│   • Reads all .claude/punts/raw/*.json                           │
│   • Walks user through each row (APPROVE/REJECT/SKIP)            │
│   • APPROVE → writes .claude/punts/<slug>.md, removes raw row    │
│   • REJECT → removes raw row                                     │
│   • SKIP → leaves raw row for next time                          │
│   • Empty raw files are deleted                                  │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ Whenever convenient: user manually runs /superpowers:brainstorming│
│   (or any other skill) on a specific .claude/punts/<slug>.md     │
└─────────────────────────────────────────────────────────────────┘
```

## Files

```
scripts/
  punts-detect.sh           Stop hook entry point (regex + fork subagent).
  punts-extract-prompt.sh   Builds the prompt for claude -p.
commands/rulez/
  punts-triage.md           /rulez:punts-triage slash command.
RULEZ.md                    Adds soft [PUNT]: marker convention.
.gitignore                  Adds .claude/punts/raw/ pattern.
settings.json               Adds Stop hook entry (template, additive merge).
bin/setup                   Extended to merge Stop hook on install.
VERSION                     1.1.4 → 1.2.0.
UPGRADE.md                  New `## To v1.2.0 — from v1.1.4` section.
```

Per-project files created at runtime:

```
<project>/.claude/punts/
  raw/<session-uuid>.json   Gitignored. Transient. One per Stop event.
  <slug>.md                 Git-tracked. Curated knowledge. One per approved issue.
```

## Components

### Stop hook (`scripts/punts-detect.sh`)

Bash script invoked by Claude Code at session end. Receives JSON via stdin
including `transcript_path` and `session_id`.

Behavior:

1. Parse stdin JSON. Bail if `transcript_path` is missing or the file does not
   exist (Stop can fire before flush — defensive).
2. Run two regex screens against the transcript file (case-insensitive):
   - `\[PUNT\]:` — explicit marker.
   - Soft phrase set:
     `pre-existing|pre existing|already broken|out of scope|not related to (this|the change)|unrelated to (this|the change)|existing (issue|bug)|leave (this|that|it) for later|leaving (this|that) (for now|alone)|outside (the|this) scope`
3. If 0 hits → `exit 0`.
4. If ≥1 hit → ensure `.claude/punts/raw/` exists in the cwd, then:
   - If `command -v claude` succeeds → fork backgrounded
     `claude -p "$prompt" --output-format json --max-turns 1`,
     redirect to `<out>.tmp`, atomic `mv` on success, `disown`.
   - If `claude` is not on PATH → fall back to writing the regex hits as a raw
     JSON object (`{"regex_hits": "<lines>", "fallback": "regex-only"}`) so
     evidence is not lost.
5. Exit 0 immediately. The subagent finishes asynchronously after the hook
   returns.

Hardening:

- `set -euo pipefail`, with `|| true` on grep (grep exits 1 on no matches).
- Atomic write: `<out>.tmp` + `mv` so partial writes never appear as `.json`.
- Concurrent sessions write to distinct `<session-uuid>.json` files — no lock
  needed.
- Hook timing budget: under 200 ms wall-clock (regex on a JSONL file is fast;
  subagent is detached and contributes 0 to hook latency).
- Logs (stdout/stderr) discarded; subagent failures are silent (fallback path
  ensures evidence is never lost).

### Subagent prompt (`scripts/punts-extract-prompt.sh`)

Outputs a self-contained prompt string consumed by `claude -p`. The prompt:

- States the goal: extract genuine punts from a Claude Code session transcript.
- Specifies the JSON schema each evidence row must conform to (see below).
- Describes the marker convention: `[PUNT]:` lines are high-confidence; soft
  phrasing should be inspected for false positives ("the pre-existing tests
  pass" is not a punt).
- Includes the absolute path of the transcript so the subagent can use Read.
- Injects the current `git branch --show-current` and ISO 8601 session-end
  timestamp so the subagent does not have to discover them.
- Requires output as a single JSON array. Empty array allowed (false-positive
  regex hits with no real punts).

### `/rulez:punts-triage` command (`commands/rulez/punts-triage.md`)

Slash command that loads a markdown skill telling Claude how to walk the raw
evidence pile interactively.

Behavior (specified in the .md skill content):

1. Glob `.claude/punts/raw/*.json`. If empty → report "No untriaged punts." and
   stop.
2. For each file (oldest first by mtime):
   - Parse JSON array of evidence rows.
   - For each row, present to the user:
     - `claim`
     - `evidence_quote` (with session date + branch context)
     - `files_mentioned`
     - `subagent_confidence` and `source` (marker vs regex)
   - Ask: APPROVE / REJECT / SKIP / MERGE WITH `<existing>`.
   - Before APPROVE, check whether a `.claude/punts/*.md` already exists with
     the same `id`. If yes, offer MERGE.
   - APPROVE:
     - Generate kebab-case slug from `claim` (truncated to ≤ 64 chars).
     - If `.claude/punts/<slug>.md` exists, append `-2`, `-3`, etc.
     - Write the file (template below).
     - Remove the row from the raw JSON.
   - REJECT: remove the row from the raw JSON.
   - SKIP: leave the row.
   - MERGE: append the new evidence quote + session id + branch to the
     existing `.md`, update `last_seen`, remove the row from the raw JSON.
3. After processing each raw file, if its rows array is empty, delete the file.
4. Report a summary: `N approved, M rejected, K skipped, P merged`.

### Curated `.md` template

```markdown
---
id: <sha1>
first_seen: 2026-05-06
last_seen: 2026-05-06
branches: [main]
sessions: [<session-uuid>]
status: open
source: marker | regex
confidence: high | medium | low
---

# <Claim as title>

## Evidence

> <evidence_quote>

(seen in session `<session-uuid>` on branch `<branch>` at <session_ended_at>)

## Files

- `src/auth/middleware.ts:42`

## Suggested next step

<dictated by user during triage, or model-suggested>
```

### `RULEZ.md` addition

Append a short section telling Claude to use the marker:

```markdown
## Punts

When you decide an issue is out-of-scope, pre-existing, or otherwise should
not be addressed in the current change, prefer to flag it on its own line as:

    [PUNT]: <one-line description of what was observed and where>

Use this only for genuine observations you are choosing not to act on, not for
neutral references (e.g. "the pre-existing tests pass" is not a punt).
```

### settings.json template addition

Adds a `Stop` hook entry to the `hooks` object:

```json
"Stop": [
  {
    "matcher": "",
    "hooks": [
      {
        "type": "command",
        "command": "bash ~/.claude/skills/rulez-claudeset/scripts/punts-detect.sh"
      }
    ]
  }
]
```

`bin/setup` is extended to merge this entry only if the user's
`~/.claude/settings.json` does not already have a `Stop` hook (same conservative
merge policy already in place for `SessionStart` and `statusLine`).

## Data schema

`raw/<session-uuid>.json` — single JSON array of evidence rows:

```json
[
  {
    "id": "<sha1 of claim, 40 hex chars>",
    "session_id": "<transcript-uuid>",
    "session_ended_at": "2026-05-06T14:30:00Z",
    "branch": "main",
    "evidence_quote": "this looks like a pre-existing bug in auth middleware — leaving it",
    "context_quote": "...3 surrounding lines from the transcript...",
    "claim": "auth middleware double-validates session tokens",
    "files_mentioned": ["src/auth/middleware.ts:42"],
    "regex_hit": "pre-existing",
    "source": "regex",
    "subagent_confidence": "medium"
  }
]
```

Field notes:

- `id` is `sha1(claim)` — claim-only hash so the same finding across multiple
  sessions has the same id, enabling triage-time dedup.
- `source` is `marker` for `[PUNT]:` derived rows and `regex` for soft-phrase
  derived rows. Used in triage to sort and to default confidence.
- Confidence rubric for the subagent:
  - `marker` source → `high` by default.
  - `regex` source with concrete file mention → `medium`.
  - `regex` source with no concrete file mention → `low`.

## Edge cases

| Case | Behavior |
|---|---|
| Stop hook fires before transcript flushed | `[[ ! -f "$transcript_path" ]] && exit 0` |
| Two parallel sessions Stop simultaneously | Each writes its own `<session_id>.json` — no collision |
| `claude` not on PATH | Fallback writes regex hits as raw JSON, evidence preserved |
| Subagent emits invalid JSON | `.tmp` left behind; never promoted to `.json` |
| Triage interrupted mid-run | SKIP-ed rows survive in their raw JSON for next run |
| Same punt across N sessions | Same `id` (SHA of claim only) → triage offers MERGE into existing `.md` |
| User runs `git clean -fd` on `.claude/punts/raw/` | Acceptable — raw is gitignored and transient |
| Rejected punt reappears in a later session | REJECT is transient — only removes the current raw row. Same `id` appearing again is re-presented at triage. Acceptable trade-off vs. persistent rejection log; revisit if it becomes a friction point. |
| `.claude/punts/<slug>.md` collision | Slug suffix increments (`-2`, `-3`) |
| Hook runs in non-git directory | `git branch --show-current` returns empty; recorded as `branch: ""` |

## Testing

| Test | Method |
|---|---|
| Regex hits + claude succeeds | Synthetic transcript with `pre-existing`, run hook, check raw JSON written with structured rows |
| Regex hits + claude missing | Override PATH to exclude claude, run hook, check fallback raw JSON written with regex hits |
| Marker hit | Synthetic transcript with `[PUNT]:` line, run hook, check `source: "marker"` row produced |
| No hits | Synthetic transcript without phrases, run hook, check no file written |
| Triage approve | Hand-craft raw JSON, run `/rulez:punts-triage`, check `.md` written and raw row removed |
| Triage merge | Two raw JSONs with same `id`, triage first → APPROVE, triage second → MERGE offered |
| Triage skip persistence | Raw row SKIP-ed, re-run triage, row reappears |
| Hook timing | `time bash punts-detect.sh < fixture.json` — must return < 200 ms wall-clock |
| Concurrency | Two `bash punts-detect.sh` invocations against same project dir — both raw files appear, no corruption |

## Release

- v1.1.4 → **v1.2.0** (additive feature; minor bump per semver).
- Two-commit pattern (matches v1.1.4 convention):
  1. `feat: detect and triage punted issues from session transcripts`
     — all behavior changes (`scripts/punts-*.sh`, `commands/rulez/punts-triage.md`,
     `RULEZ.md`, `.gitignore`, `settings.json`, `bin/setup`).
  2. `chore: release v1.2.0` — `VERSION` + `UPGRADE.md` only.
- UPGRADE.md section explains:
  - Opt-in via `bin/setup` (which adds the Stop hook on install).
  - Per-project `.claude/punts/` directory created on first hit.
  - `/rulez:punts-triage` walks accumulated evidence interactively.
  - Marker convention `[PUNT]: <reason>` is now in RULEZ.md.

## Out of scope (deferred)

- **Cross-project consolidation.** No global view of punts across projects;
  each project owns its own `.claude/punts/`. Could revisit if the per-project
  approach proves siloed.
- **Auto-promote.** No automatic raw → `.md` promotion; human triage gate is
  intentional. The whole point is that raw evidence is *evidence*, not a todo
  list.
- **Statusline indicator.** No "🟡 N untriaged punts" badge in the statusline
  (initial design floated this; deferred to keep v1.2.0 focused). Easy to add
  in v1.2.x if it proves useful.
- **GitHub issue auto-creation.** No bridge from `.md` to GitHub issues; user
  invokes `/rulez:add-issue` manually when ready.
