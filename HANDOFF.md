# Handoff

## Task

Two patches on top of v1.3.0:

1. **v1.3.1** — migrate `/rulez:punts-triage`'s enrichment step from
   shelling out to `scripts/punts-enrich.sh` (which loops `claude -p`
   per slice) to dispatching the in-session **Agent (Task) tool**, one
   Agent per slice, in parallel batches of up to 8. The script path
   stays around for batch / non-interactive back-fills.
2. **v1.3.2** — small UX tweak to `/rulez:handoff`: end the assistant's
   reply with a literal nudge telling the user to run `/compact` so the
   now-stale conversation context can be freed.

## Current State

- Branch: `main`, in sync with `origin/main` (everything pushed).
- Working tree: only `tmp/` untracked; no uncommitted edits aside from
  this HANDOFF.md.
- VERSION: `1.3.2`.
- Tests: `bash tests/punts/run-tests.sh` → **34/34 pass**.
- Global install at `~/.claude/skills/rulez-claudeset/` is on **1.3.2**
  (pulled, `bin/setup -q` re-ran successfully).

Recent commit chain (top of `git log --oneline`):

```
chore: release v1.3.2
feat: handoff command nudges user to /compact after committing
b5c7488 chore: release v1.3.1
d9601f0 refactor: triage enriches via Agent tool, not claude -p script
bfb1e1b docs: handoff — Make the punt-detection Stop hook viable …
e0bc76c chore: release v1.3.0
```

Files touched this session:

- `commands/rulez/punts-triage.md` — step 1 fully rewritten to use the
  Agent tool with parallel dispatches and JSON validation.
- `commands/rulez/handoff.md` — added step 5 (the `/compact` nudge).
- `UPGRADE.md` — two new top sections (v1.3.2, v1.3.1).
- `VERSION` — `1.3.0` → `1.3.1` → `1.3.2`.

## What Worked

### v1.3.1 ship sequence

- Re-grounded in the v1.3.0 reality first (read
  `commands/rulez/punts-triage.md`, `scripts/punts-enrich.sh`,
  `scripts/punts-extract-prompt.sh`, current UPGRADE.md, recent commits).
- Confirmed baseline 34/34 tests passed before edits.
- Rewrote step 1 of `commands/rulez/punts-triage.md` end-to-end:
  - List `.claude/punts/raw/*.json` filtered by
    `.fallback == "regex-only"`.
  - For each, locate slice at
    `.claude/punts/state/slice-<basename>.jsonl`.
  - Read `session_id` and `regex_hits` via `jq -r`.
  - Build the prompt by running
    `bash ~/.claude/skills/rulez-claudeset/scripts/punts-extract-prompt.sh "$slice" "$session_id" "$regex_hits"`.
  - Dispatch one `Agent` per file in a single message
    (`subagent_type: "general-purpose"`, prompt = step-d output).
  - Parallelism cap: 8 per round; `>~24` files → offer the script
    fallback.
  - Extract JSON array from each Agent's message text, validate with
    `jq -e .`, overwrite raw file on success and `rm` slice; leave
    both intact for retry on failure.
  - Report `enriched=N failed=M skipped_no_slice=K already_structured=L`.
- Added a closing note that `scripts/punts-enrich.sh` and
  `/rulez:punts-enrich` remain for batch back-fills.
- Bumped `VERSION` to 1.3.1.
- Added `## To v1.3.1 — from v1.3.0` section to UPGRADE.md (motivation,
  why-now, what's-unchanged, migration).
- Two-commit pattern: `d9601f0` (substantive) + `b5c7488` (release).
- Pushed, pulled into global install, re-ran `bin/setup -q`. Confirmed
  `~/.claude/skills/rulez-claudeset/VERSION` reads `1.3.1`.

### v1.3.2 ship sequence

- Discussed with user: built-in `/compact` cannot be invoked
  programmatically from inside a skill — only the user can type it.
  Closest workaround: have the handoff command end with a literal
  one-line prompt.
- Added step 5 to `commands/rulez/handoff.md` instructing the
  assistant to end its reply with:
  `> Handoff committed. Run \`/compact\` now to free up context for the next task.`
- Bumped VERSION to 1.3.2 and added `## To v1.3.2 — from v1.3.1`
  section to UPGRADE.md.
- Two-commit pattern again. Pushed, pulled into global install,
  re-ran setup; global VERSION is `1.3.2`.

## What Didn't Work

Nothing concrete failed this session. A few explicit non-goals:

- **`/rulez:punts-enrich` and `scripts/punts-enrich.sh` left
  untouched.** They still use `claude -p --output-format json`
  internally and therefore still emit the `{result: "..."}` wrapper
  shape — the long-standing wrapper-vs-bare-array `[PUNT]` from prior
  sessions still applies on the script path. The Agent path inside
  triage sidesteps it because we parse plain message text.
- **No new tests added for v1.3.1 or v1.3.2.** Triage and handoff are
  both prose-only `.md` slash commands; the existing bash test suite
  exercises scripts. Live smoke-testing is the right gate for the
  triage refactor (see Next Steps).

## Next Steps

Ordered by priority:

1. **Live smoke-test v1.3.1 end-to-end.** Trigger a real Stop on a
   session containing punt phrasing in this very repo. Verify:
   - Hook writes `.claude/punts/raw/<sid>-<chunk_end>-<pid>.json`
     with `fallback: "regex-only"`.
   - Matching slice exists in `.claude/punts/state/slice-...`.
   - Then run `/rulez:punts-triage` — confirm it dispatches Agents in
     parallel, slice files disappear, raw files become structured
     arrays.
2. **Wrapper-vs-bare-array on the script path.** Long-standing
   carryover. `scripts/punts-enrich.sh` still relies on
   `claude -p --output-format json` and the result is a wrapper
   object. Either unwrap inside the script, or migrate the script to
   `--output-format text` and parse the array out the same way the
   triage Agent path does. See prior HANDOFFs for context.
3. **Slice-file accumulation cleanup.** UPGRADE.md (v1.3.0 section)
   recommends `find .claude/punts/state -name 'slice-*' -mtime +14
   -delete` opportunistically. Not implemented in the hook yet — add
   it cheaply at the top of `punts-detect.sh` when slice budget
   becomes a real concern.
4. **Test cleanup race** carryover from prior session — see prior
   HANDOFFs.
5. **Carryovers from earlier sessions** (auto-update.sh hardening,
   statusline auto_compact_threshold, etc.). None blocking.

## Key Decisions

- **Two enrichment paths now coexist.** Agent (in-session,
  triage-driven, parallel) is the default; script (`claude -p`,
  sequential) is for batch / cron / non-interactive shells. They share
  `punts-extract-prompt.sh` so the prompt body is identical.
- **Parallelism cap of 8** in triage step 1, with a soft offer to
  fall back to the script if the regex-only backlog exceeds ~24
  files. Cost isn't the reason — rate limits and per-round
  wall-clock are.
- **`general-purpose` subagent type** for the enrichment Agents.
  Considered defining a dedicated `punts-extractor` agent, but
  declined: more infra than v1.3.1 needs, and the prompt itself is
  already self-contained.
- **JSON parsing on the Agent path is naked text scanning** ("first
  `[ ... ]` block in the message"). This is acceptable because the
  prompt explicitly asks for a single JSON array and Agents have
  proven reliable at honoring that. The script path's
  `--output-format json` wrapper is intentionally not removed yet —
  doing so would change the script path's contract; it's tracked as
  Next Step #2.
- **`/compact` is a client-side command.** The handoff skill cannot
  invoke it; the v1.3.2 nudge is the cleanest available workaround.
- **The handoff command's step 5 is in effect from v1.3.2 onward.**
  Slash commands are loaded at session start, so the new behaviour
  fires on the *next* `/rulez:handoff` invocation, not necessarily on
  the one that produced this document.
