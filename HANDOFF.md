# Handoff

## Task

Tighten `/rulez:what-have-i-done` after the v1.4.0/v1.4.1 ship. Each
new live run surfaced a new flaw; each was patched inline as a
focused release rather than going back through the full
brainstorm → spec → plan → subagent flow.

Four patches landed this session: **v1.4.2, v1.4.3, v1.4.4, v1.4.5.**

## Current State

- Branch: `main`, in sync with `origin/main`.
- Working tree: only `tmp/` outside the repo.
- VERSION: `1.4.5`.
- Global install at `~/.claude/skills/rulez-claudeset/` is on
  **1.4.5** — pulled, `bin/setup -q` re-ran, four whid script
  permissions confirmed merged into `~/.claude/settings.json`.
- Tests: 34 punts + 38 what-have-i-done = **72/72 green** (one extra
  whid assertion landed in v1.4.5 around the no-marker rule).

Commit chain since the prior handoff (`3ad5545`):

```
dd5b934 chore: release v1.4.5
49b2670 fix: /rulez:what-have-i-done omits empty projects on every date
f45f144 chore: release v1.4.4
bdf9dea fix: /rulez:what-have-i-done bullets carry signal, not artifacts
c3112b8 chore: release v1.4.3
7127c06 fix: /rulez:what-have-i-done bullets stay flat — no sub-items
5f620a0 chore: release v1.4.2
8c6a384 fix: /rulez:what-have-i-done discovers stale-mtime projects, groups by repo, renders multi-line bullets
```

Files touched across the four releases:

- `scripts/what-have-i-done-discover.sh` — JSONL-mtime gate, .cwd
  scan over first ~200 lines, GitHub repo display name (3rd column),
  dedupe by display_name (v1.4.2).
- `scripts/what-have-i-done-render.sh` — index-based bullet access
  for multi-line tolerance (v1.4.2); empty-project rule made
  symmetric across every date, no-activity marker removed (v1.4.5).
- `commands/rulez/what-have-i-done.md` — three Agent-prompt rewrites
  (v1.4.2 → v1.4.3 → v1.4.4) plus the Notes section update for the
  symmetric empty-project rule (v1.4.5).
- `tests/what-have-i-done/test-render.sh`,
  `tests/what-have-i-done/test-finalize.sh`, and
  `tests/what-have-i-done/fixtures/render-golden.md` — updated for
  v1.4.5's no-marker behaviour. 4 assertions flipped from
  `assert_contains "(no git activity in window)"` to
  `assert_not_contains`.
- `README.md` — "What Have I Done" prose updated for v1.4.5.
- `UPGRADE.md` — four new sections at the top, one per release.
- `VERSION` — `1.4.1` → `1.4.2` → `1.4.3` → `1.4.4` → `1.4.5`.

## What Worked

### v1.4.2 — discovery + display names + multi-line bullets

The first live run after v1.4.1 (`/rulez:what-have-i-done` in a
fresh session) flagged three real flaws: `AI-infrastructure-architect-search`
was missing entirely, projects were labelled by on-disk folder name
(e.g. `26.03-dc-import-2026` instead of `dc-import-2026`), and one
day's bullets read like a process diary rather than naming what got
built.

Root cause for the missing project: `find ~/.claude/projects -mtime -N`
gates on **directory mtime**, but on macOS appending to an existing
JSONL doesn't bump the parent dir's mtime. The
`AI-infrastructure-architect-search` dir's mtime was Apr 25 (14 days
old) while the JSONL inside it had mtime May 9 (today). Confirmed
with `stat -f '%Sm %N'`. Discovery now scans every project subdir
and gates on the most-recent JSONL's file mtime instead.

Bonus root cause for the same project: its first JSONL line was a
`file-history-snapshot` record with no `.cwd` field. Discovery used
to read only line 1; v1.4.2 scans the first ~200 lines for the
earliest record carrying `.cwd`.

Display names: discovery emits a third tab-separated column. If
`git -C <real_cwd> remote get-url origin` succeeds, the column is
`basename "$remote_url" .git`; otherwise it falls back to
`basename "$real_cwd"`. Dedupe is by column 3 so two checkouts of
the same repo collapse to one row. Live verification:
`AI-infrastructure-architect-search`, `dc-import-2026`,
`rulez-claudeset`, `barevibe-mcp` all surfaced cleanly.

Renderer also patched in v1.4.2 to handle bullet strings with
embedded newlines via index-based `jq -r ".[$i]"` access, since
v1.4.2's prompt invited per-bullet sub-items via `\n  - ` syntax.
The defensive multi-line tolerance stayed in even after v1.4.3
banned sub-items.

### v1.4.3 — flat-only bullets

User feedback after the v1.4.2 smoke run: *"Let's drop second level
bullets - they too verbose while first level is clear enough."* The
sub-bullet syntax was reversed — bullets must now be single-line,
1–3 per day per project. Two Bad examples in the prompt
("steps-not-substance", "nested/multi-line"); one Good with all
artifacts crammed into a parenthetical.

### v1.4.4 — signal, not artifacts

Live run after v1.4.3 showed exactly the failure mode option C
predicted in the brainstorm: the model dutifully shoved every
artifact (PR #s, file paths, SHAs) into the inline parenthetical,
producing 250–400-character lead bullets. Same density as v1.4.2's
nested form, just less readable. The brainstorm settled on
**Option A: lead-bullet only, drop the artifacts.**

Three concrete prompt changes landed:

1. Reframed the parenthetical's role as **signal — the why**: a
   metric ("777/779 LW rows on schema_version 1.0"), a symptom
   ("Telegram alert spam"), or a trigger ("staging migrate.ts
   auto-bootstrap bug"). Not a list of artifacts.
2. New Bad/Good set: three Bads (steps-not-substance, nested,
   artifact-dump-in-parenthetical) plus a Good rebuilt from the
   actual short v1.4.2 lead bullets the user pasted as the target.
3. Explicit DROP list: PR numbers, commit SHAs, file paths,
   semicolon-enumerations.

Trade-off named explicitly in the UPGRADE.md: PR numbers and file
paths leave the rollup. The dated MD file is for impostor-syndrome
relief, not auditing.

### v1.4.5 — symmetric empty-project rule

Live run after v1.4.4 looked clean for the bullets it had, but
three of four projects on a typical day had no activity for today
and were rendered with `- (no git activity in window)` as a
defensive "the project was checked" marker. The rollup opened with
a wall of negative-space placeholders before the actual content.

User asked to omit them. The renderer now applies the same rule to
every date: skip projects with no bullets, and skip date headings
entirely when no project under them has bullets. The `(no git
activity in window)` string is gone entirely — `grep -r` confirms
no remaining occurrences.

Tests, slash-command Notes, and README all updated. Golden fixture
regenerated. 4 assertions flipped from `assert_contains` to
`assert_not_contains`; one renamed
(`test_render_shows_no_activity_for_today_empty_project` →
`test_render_omits_empty_today_project`).

## What Didn't Work

- **The v1.4.3 prompt change was the wrong direction.** Banning
  sub-items without naming what the parenthetical is *for* invited
  the model to use the parenthetical as a junk drawer. The
  brainstorm before v1.4.4 surfaced this: "examples beat rules".
  v1.4.3's two Bad examples didn't include a v1.4.3-shaped failure,
  so the model had no contrast to avoid. Lesson reinforced: when
  rewriting a prompt to fix a regression, the new Bad example
  should be *the previous version's Good example*.
- **Tests were skipped during v1.4.2's "skip tests" instruction
  but later updated when the renderer changed in v1.4.5.** Drawing
  the line: "skip tests" means don't write *new* fixture-coverage
  tests, but stale assertions on removed behaviour have to be
  updated to keep the suite honest. Worth being explicit about
  this distinction in future sessions.
- **The harness heredoc guard kept biting on commit messages.**
  Two of the four releases had to fall back to writing the message
  body to `tmp/whid-1.4.x-fix-msg.txt` and using `git commit -F`
  because the `cat <<'EOF'` form tripped the parser on apostrophes
  inside the body. The Write-tool-then-`-F` workaround is reliable;
  use it from the start when commit messages contain apostrophes,
  backticks, or "$" expansions.

## Next Steps

Ordered by priority:

1. **Live smoke-test v1.4.5 end-to-end.** Run `/rulez:what-have-i-done`
   in a fresh session — should produce no approval prompts (still
   the v1.4.1 silent-execution win), no `(no git activity in window)`
   markers, lead bullets that read like the v1.4.2 short form
   ("Acted on API team's staging-dump review (777/779 LW rows still
   emitting schema_version 1.0, plus Telegram alert spam)"). If
   bullets drift verbose again, the lever is the third Bad example
   in the prompt — sharpen it.
2. **Mode B (`/rulez:what-have-i-done full`) if traceability ever
   matters.** Brainstorm option B is parked in the v1.4.4 UPGRADE
   note: a separate command or flag that brings back v1.4.2's
   nested form for when you actually need PR numbers. Not built
   yet; only build when there's a concrete moment of "I want to see
   the PR numbers and the rollup is the right entry point".
3. **Carryovers still valid from v1.3.2 / v1.3.3 handoffs:**
   - Live smoke-test v1.3.1 punt-detection end-to-end.
   - Wrapper-vs-bare-array fix on `scripts/punts-enrich.sh`.
   - Slice-file accumulation cleanup in `punts-detect.sh`.
   - Test cleanup race carryover.
   - Auto-update.sh hardening, statusline auto_compact_threshold.
4. **Open follow-ups (none merit a v1.4.6):**
   - `YESTERDAY` variable still emitted by
     `scripts/what-have-i-done-context.sh` but no longer read by the
     slash command. Could drop after a few cycles.
   - Renderer's outer `for date in $DATES` still relies on
     word-splitting; switch to `while IFS= read -r date` for
     symmetry with the inner project loop.

## Key Decisions

- **Inline patches all the way through.** v1.4.2/3/4/5 each had a
  clear user direction (no design forks worth brainstorming over),
  so none went through `/superpowers:brainstorming` ceremony. The
  brainstorm before v1.4.4 was the exception — option A vs B vs C
  was a real trade-off and the user wanted to be educated before
  picking. That brainstorm was kept lightweight (no spec, no plan,
  no subagent flow); it just informed the prompt rewrite.
- **The dated rollup file is for impostor-syndrome relief, not
  auditing.** Said out loud in v1.4.4 UPGRADE. PR numbers and file
  paths leave the bullet on purpose. If you want them, `git log`
  and HANDOFF.md are the source of truth.
- **Symmetric empty-project rule (v1.4.5).** The "today still
  prints empty projects" exception was a defensive choice that
  traded readability for one small reassurance ("the project was
  checked"). Reassurance not worth the cost. Same rule for every
  date is simpler to reason about and produces a tighter rollup.
- **Two-commit release pattern held throughout.** `fix:` for
  substantive changes, then `chore: release vX.Y.Z` to bump
  VERSION + UPGRADE.md. Eight commits across four releases this
  session.
- **Renderer's multi-line tolerance stays even though the prompt
  no longer asks for it.** Defensive support — if a future Agent
  ever returns a multi-line bullet, the renderer handles it. The
  v1.4.4 prompt explicitly forbids multi-line, so this is purely
  belt-and-braces.
- **`AI-infrastructure-architect-search`'s rediscovery is the
  whole point of v1.4.2.** Confirmed working live: it shows up in
  `bash discover.sh 3` output and gets summarised by the slash
  command. The same fix benefits any project where Claude Code
  reuses a long-lived JSONL session (which is most of them once
  the file gets > a few hundred KB).
