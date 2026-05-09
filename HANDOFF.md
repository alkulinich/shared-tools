# Handoff

## Task

Two pieces of work in one session:

1. **Push five slash commands through Agent-tool dispatch** to keep
   large outputs (PR diffs, file bodies, test logs, UPGRADE.md
   history) out of the main thread's context. Shipped as **v1.5.0**.
2. **Clean up UPGRADE.md** which had drifted from "what does the user
   need to do?" into a maintainer-facing changelog. New shape:
   **Action + Caveat** per section, nothing else.

Plus a small README.md polish (Uninstall section) committed at the
top of the session.

## Current State

- Branch: `main`, pushed to `origin/main`.
- Working tree: only `tmp/` outside the repo.
- VERSION: `1.5.0`.
- Global install at `~/.claude/skills/rulez-claudeset/` is on **1.5.0**
  (pulled twice during the session — once after the v1.5.0 release,
  once after the UPGRADE.md cleanup).

Commit chain since the prior handoff (`1d3dfd3`):

```
e95f6a8 docs: CLAUDE.md locks in UPGRADE.md action+caveat shape
9bc26ee docs: UPGRADE.md cut to action+caveat per section
7072eb0 chore: release v1.5.0
a79a2e3 feat: /rulez:update-claudeset slices UPGRADE.md in Agent
2a1d7f2 feat: /rulez:push-fixes drafts commit via Agent
1a3baa2 feat: /rulez:merge-pr open-issues table runs in Agent
838a15d feat: /rulez:create-pr drafts PR via Agent, main thread sees only the proposal
7ea0c12 feat: /rulez:test-pr dispatches plan-builder + plan-executor Agents
8234813 docs: README documents uninstall
1d3dfd3 docs: handoff — Tighten /rulez:what-have-i-done after the v1.4.0/v1.4.1 ship
```

## What Worked

### v1.5.0 — Agent dispatch in five commands

Conventions copied verbatim from the existing exemplars
(`commands/rulez/what-have-i-done.md`, `commands/rulez/punts-triage.md`):
`subagent_type: "general-purpose"`, JSON return validated with
`jq -e .`, single retry on parse failure, **visible** fallback to
inline on second failure (never a silent stub — these are
user-visible actions, not summaries). Single Agent per command (no
parallelism needed; 8-per-round cap doesn't apply here).

The git-* shell scripts behind the four PR/branch commands were
already context-safe (only short status output) — confirmed by Explore
agent before writing the plan. So all the pollution lived inside the
`.md` files' main-thread gathering steps, and that's where the fixes
landed.

- **`commands/rulez/test-pr.md`** (biggest rewrite, 201+/163-) — two
  Agent dispatches:
  1. **Plan-builder**: cd → `gh pr view --json` → `gh pr diff` →
     detect linked issue → `gh issue view --json` → read changed
     files → return JSON with title, branch, base, linked_issue,
     files, test_plan array, risk_notes.
  2. **Plan-executor**: cd → run each `cmd` from the test_plan with
     `set +e`-style capture, mark PASS/FAIL, capture first ~20 lines
     of stdout+stderr on failure, always run `docker compose down` at
     the end. Auto-fix lint warnings folded in as a final optional
     step (returns `lint_autofix_files` for main thread to suggest
     `/rulez:push-fixes`).

  The user-chosen trade-off (asked via AskUserQuestion in plan mode):
  **both** phases go through Agents, no live test progress in the main
  thread — final pass/fail table only.

- **`commands/rulez/create-pr.md`** (84+/33-) — one Agent
  (PR-drafter): cd → `npx eslint --fix` on changed source files →
  `git status` → `git diff` → `git log -5` → decide branch / title /
  body / files / lint_autofix_files → return JSON. Main thread
  renders the proposal block, then immediately runs
  `scripts/git-create-pr.sh` (no approval prompt — explicit existing
  contract).

- **`commands/rulez/merge-pr.md`** (50+/17-) — step 7 only. One Agent
  (open-issues-table): cd → `gh issue list` + `gh pr list` → match
  branch/title against issue numbers → build markdown table → choose
  next-issue suggestion (priority:high/urgent first, then oldest) →
  return `{table, suggested_next}`. Steps 1–6 (PR validation, merge
  plan, script execution, close-linked-issues) and step 8 stay on
  main thread.

- **`commands/rulez/push-fixes.md`** (60+/18-) — one Agent
  (fix-drafter): cd → `git branch --show-current` → `git status` →
  `git diff` → return `{branch, files, commit_message, on_main}`.
  Main thread checks `on_main` (warns + stops if true), renders the
  proposal, asks user to confirm/edit, runs
  `scripts/git-push-fixes.sh`.

- **`commands/rulez/update-claudeset.md`** (47+/12-) — step 5 only.
  Step 1 now snapshots `OLD_VERSION` before the pull; step 4
  captures `NEW_VERSION`. Step 5 dispatches an Agent (UPGRADE-slicer)
  that reads UPGRADE.md inside its own context and returns only the
  sections strictly greater than `OLD_VERSION` and ≤ `NEW_VERSION`,
  semver-compared. Returns markdown body (not JSON — pure
  text-extraction task). Skipped entirely when `OLD == NEW`.

- **`UPGRADE.md` v1.5.0 section** — full **Action + Caveat** shape,
  including the explicit per-project-installs action (re-run
  `bin/setup-per-project.sh`) and the test-pr live-progress caveat.

Shipped as 7 commits (1 docs README + 5 feat per-command + 1 chore
release), pushed, pulled into the global install, `bin/setup -q`
re-run. `cat ~/.claude/skills/rulez-claudeset/VERSION` returned
`1.5.0`.

### UPGRADE.md cleanup

Brainstorm produced 6 options; user agreed with **Option B**
(judgmental re-categorization) plus a CLAUDE.md rule to keep future
sections in the new shape.

- **`UPGRADE.md`** — 815 → 371 lines (148+/593-, 56% reduction).
  Per-section shape is now `**Action:** <one-liner>` plus optional
  `**Caveat:** <one-liner-or-bullets>`. Internal change writeups,
  motivation prose, and test-added notes all dropped — those belong
  in commit messages. Legacy v1.0.0 migration sections at the bottom
  (~130 lines, two sections: "from shared-tools (GitHub Flow)" and
  "from legacy (develop branch)") kept **verbatim** — anyone
  arriving from a pre-1.0 install needs every step. All 24 `## To
  vX.Y.Z — from vA.B.C` headings preserved so the Agent slicer in
  `/rulez:update-claudeset` still matches.

- **`CLAUDE.md`** — extended the "Version Bumping" section with one
  paragraph spelling out the user-facing/Action+Caveat-only rule, so
  future v1.5.x / v1.6.0 sections start in the right shape.

Two commits, pushed, pulled into the global install.

## What Didn't Work

- **One `Write` attempt failed** because I called Write on
  `commands/rulez/update-claudeset.md` and `CLAUDE.md` without
  reading them first in the same session. The harness blocked it
  with a clear error; I read the file then re-Wrote. Trivial — flag
  for future reference: `Write` on an existing file requires a Read
  in the current session.
- **One small follow-up edit on merge-pr.md** — the initial Edit
  used `<project_root>` as a substitution placeholder without
  telling the main thread how to capture it. Fixed in a follow-up
  Edit ("set `PROJECT_ROOT=$(pwd)` first"). Caught at review time, not
  by the user. Could have been avoided by mirroring the explicit
  `PROJECT_ROOT=$(pwd)` line that test-pr.md, create-pr.md, and
  push-fixes.md all spell out.

No dead-end approaches, no reversed decisions. Auto-mode worked
cleanly through both the v1.5.0 ship and the UPGRADE.md cleanup.

## Next Steps

Ordered by priority:

1. **Live smoke-test v1.5.0 end-to-end.** Each of the five commands
   needs a real-world run to confirm the diffs / file bodies /
   UPGRADE.md history actually stay out of the main thread:
   - `/rulez:test-pr <real-pr>` — plan render comes from JSON, results
     table comes from JSON, no diff text or full file bodies in main
     thread. Verify a deliberately-broken PR still surfaces enough
     failure context (first ~20 lines per failing step) to be
     actionable.
   - `/rulez:create-pr` (with real WIP) — main thread shows only the
     proposed PR block, not the diff. Script runs successfully and
     resulting PR matches the proposal.
   - `/rulez:merge-pr <real-pr>` — step 7 main thread shows only the
     open-issues table + suggested-next line; no raw `gh issue list`
     JSON.
   - `/rulez:push-fixes` (with real WIP) — main thread shows only the
     proposed commit block, not the diff.
   - `/rulez:update-claudeset` — patch local VERSION to a previous
     version, run the command, confirm only the relevant
     `## To vX.Y.Z` sections appear in main thread (not the full 371
     lines).

2. **Mode B (`/rulez:what-have-i-done full`) if traceability ever
   matters.** Brainstorm option B from the prior session is parked in
   the v1.4.4 UPGRADE note (now compressed into a one-line caveat in
   the new shape — content is the same). Not built yet; only build
   when there's a concrete moment of "I want to see the PR numbers
   and the rollup is the right entry point".

3. **Carryovers still valid from earlier handoffs:**
   - Live smoke-test v1.3.1 punt-detection end-to-end.
   - Wrapper-vs-bare-array fix on `scripts/punts-enrich.sh`.
   - Slice-file accumulation cleanup in `punts-detect.sh`.
   - Test cleanup race carryover.
   - Auto-update.sh hardening, statusline auto_compact_threshold.

4. **Open follow-ups (none merit a v1.5.1 yet):**
   - `YESTERDAY` variable still emitted by
     `scripts/what-have-i-done-context.sh` but no longer read by the
     slash command.
   - Renderer's outer `for date in $DATES` still relies on
     word-splitting; switch to `while IFS= read -r date`.

## Key Decisions

- **Both phases of `/rulez:test-pr` go through Agents (Phase 1 plan
  + Phase 3 execute).** User-chosen via AskUserQuestion in plan mode.
  Trade-off named explicitly in v1.5.0 UPGRADE.md caveat: no live
  test progress in main thread, only a final pass/fail table with
  first-20-lines failure summary. If a step fails opaquely, re-run
  the failing command manually.

- **Visible fallback on second-Agent-failure, never a silent stub.**
  These are user-visible actions, not summaries, so an Agent failure
  must surface — main thread prints
  `(Agent dispatch failed for <name>, falling back to inline)` and
  runs the gathering inline. Different from
  `/rulez:what-have-i-done`'s `{"<TODAY>": ["(summary failed)"]}`
  stub, which fits *that* command because summaries can degrade
  gracefully.

- **Six commits for the v1.5.0 release, not one big squash.** One
  `feat:` per command file, then `chore: release v1.5.0`. Mirrors
  the established pattern (v1.4.2–v1.4.5 each used the
  `fix:`/`feat:` + `chore: release` shape). Adds a 7th commit for
  the README uninstall section because that was unrelated to v1.5.0
  and shouldn't ride in any of the feat commits. CLAUDE.md +
  UPGRADE.md cleanup landed in two more commits *after* the release
  — they're a separate mini-task, not part of v1.5.0.

- **UPGRADE.md cleanup landed AFTER v1.5.0**, not as part of it.
  Two reasons: (a) it's a separate user concern surfaced by a
  separate brainstorm; (b) v1.5.0's UPGRADE.md section was *already*
  in the new shape (action + caveat per the user's written-while-
  drafting feedback), so the cleanup didn't need to also rewrite the
  newest section. Future cleanups follow the rule in CLAUDE.md from
  commit `e95f6a8`.

- **Legacy v1.0.0 migration sections kept verbatim.** Two sections
  at the bottom of UPGRADE.md (~130 lines), one per legacy install
  shape. One-way door: nobody on those installs is going to
  upgrade today, but if they ever do, every step matters. Compressing
  them is wasted work and risks dropping a step nobody will check.

- **Reframed brainstorm.** User said "drop 'No user action required'
  steps". Literal interpretation would have thrown out caveats the
  user genuinely needs to know (e.g., v1.4.4's "PR numbers leave the
  rollup"). Recognized that the underlying intent was "drop the
  changelog noise" not "filter on the literal phrase", and proposed
  Option B (judgmental Action + Caveat). User agreed.
