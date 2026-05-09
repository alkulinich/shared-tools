# Handoff

## Task

Build `/rulez:what-have-i-done [N]` — a cross-project rollup that
summarizes the last N calendar days of HANDOFF.md commits + recent
commit subjects across every Claude project the user touched. Built
to push back on impostor syndrome on days when it doesn't feel like
much shipped. Two ship cycles in this session: v1.4.0 (initial) and
v1.4.1 (patch after the live smoke test surfaced two real flaws).

## Current State

- Branch: `main`, in sync with `origin/main`.
- Working tree: only `tmp/` and the smoke-test-overwritten
  `~/.claude/what-have-i-done/2026-05-09.md` outside the repo (a
  re-run of `/rulez:what-have-i-done` will regenerate it cleanly with
  the new v1.4.1 grouped bullets).
- VERSION: `1.4.1`.
- Global install at `~/.claude/skills/rulez-claudeset/` is on
  **1.4.1** — pulled, `bin/setup -q` re-ran, four whid script
  permissions confirmed merged into `~/.claude/settings.json`.
- Tests: 34 punts + 35 what-have-i-done = **69/69 green**.

Recent commit chain (top of `git log --oneline`):

```
6b45ff6 chore: release v1.4.1
d0e35e7 fix: /rulez:what-have-i-done runs silently with grouped bullets
f719ce4 chore: release v1.4.0
9eff149 docs: tighten what-have-i-done README prose
7af68a3 docs: README documents /rulez:what-have-i-done
da67255 feat: /rulez:what-have-i-done slash command
ada7c1e feat: what-have-i-done discovery script
5e3a4ff feat: what-have-i-done renderer (pure stdin→markdown)
42d46a9 test: scaffold tests/what-have-i-done/ runner and helpers
```

Files added/modified across both releases:

- New: `commands/rulez/what-have-i-done.md` (slash command).
- New: `scripts/what-have-i-done-context.sh` (date window, KEY=VALUE).
- New: `scripts/what-have-i-done-discover.sh` (recent project dirs → real cwd).
- New: `scripts/what-have-i-done-render.sh` (pure stdin→markdown).
- New: `scripts/what-have-i-done-finalize.sh` (merge + render + write + print).
- New: `tests/what-have-i-done/{run-tests,helpers,test-{render,discover,context,finalize}}.sh`
  + `fixtures/{render-input.json,render-golden.md}`.
- Modified: `settings.json` (four whid script allowlist entries +
  `Skill(rulez:what-have-i-done)`).
- Modified: `README.md` (commands table row, four utility-script rows,
  new "## What Have I Done" section, prose tightened to match Punts tone).
- Modified: `UPGRADE.md` (sections for v1.4.0 and v1.4.1 at the top).
- Modified: `VERSION` (1.3.3 → 1.4.0 → 1.4.1).

## What Worked

### v1.4.0 — initial ship via the brainstorming → spec → plan → subagent-driven flow

- **Brainstorm** (`/superpowers:brainstorming`) settled five design
  forks with single-question rounds: evidence source (HANDOFF.md +
  recent commits), time bucketing (calendar days, configurable count),
  output target (chat + dated MD), summary shape (grouped by project,
  1–3 bullets each), agent shape (one Agent per project in parallel,
  each returns formatted bullets directly).
- **Spec doc** committed at `docs/superpowers/specs/2026-05-09-what-have-i-done-design.md`
  with a self-review pass that fixed two minor clarity gaps inline
  (basename derivation, dates list usage).
- **Plan** at `docs/superpowers/plans/2026-05-09-what-have-i-done.md`
  decomposed into 6 tasks: scaffold tests → renderer (TDD) → discovery
  (TDD) → slash command → README → release.
- **Subagent-driven execution** with two-stage review (spec compliance
  then code quality) per task. All six tasks landed cleanly with
  three plan-defect catches by the implementer subagents:
  - jq `keys[]` → `keys_unsorted[]` so project insertion order is
    preserved end-to-end (the original sort would have re-ordered the
    golden fixture).
  - Test-side awk range form `'/A/,/B/'` collapsing to a single line
    on BSD awk when both regexes match `## Yesterday (...)` →
    rewrote to flag form `awk '/^## Yesterday/{f=1;next} /^## /{f=0} f'`.
  - `declare -A` (bash 4+) → `awk -F'\t' '!seen[$1]++'` so the
    discovery script runs on stock macOS bash 3.2.57.
- Final cross-implementation reviewer returned **READY TO MERGE** with
  five non-blocking minor follow-ups noted (one of which —
  empty-prior-day heading — got fixed in v1.4.1; see below).
- Released as `f719ce4 chore: release v1.4.0`, pushed, pulled into
  global install. 9 new asserts, 0 failures alongside 34 punts.

### v1.4.1 — patch after live smoke test

The first real-world `/rulez:what-have-i-done` invocation surfaced two
issues at once:

1. The user got prompted **three times** for harness approval —
   `(N-1)` arithmetic + a brace+quote heredoc for date math + another
   heredoc for the merge JSON.
2. The dc-import-2026 project's day got summarized into 6 short
   one-per-commit bullets, which read like a commit log, not a
   standup.

Both fixed inline (no brainstorm/plan/subagent ceremony — it was a
focused patch):

- **Silent execution.** Moved date math into
  `scripts/what-have-i-done-context.sh` (KEY=VALUE output) and the
  merge + render + write into `scripts/what-have-i-done-finalize.sh`.
  Slash command no longer composes any heredoc bash; it uses the
  **Write tool** to drop per-Agent JSONs to `/tmp/whid-<basename>.json`,
  then a single `bash …finalize.sh "$TODAY" "$DATES_LIST" name path …`
  call does the rest. Whitelisted all four whid scripts in
  `settings.json`; `Skill(rulez:what-have-i-done)` added too.
- **Grouped bullets.** Per-project Agent prompt step 6 explicitly
  asks for 1–3 bullets of 1–2 sentences each, "merging related
  commits into a single narrative line", with a Bad/Good worked
  example (LeaseWeb step 3 hardening as the contrast pair).
- **Empty prior-day headings suppressed.** Renderer now does a
  pre-pass per date for prior days; if no project under that date has
  bullets, skips the heading entirely. Today still always prints (it
  carries the "(no git activity in window)" markers). Flagged as a
  minor in the v1.4.0 final review; fixed here while in the
  neighbourhood.
- Two new test files: `test-context.sh` (4 asserts including a
  `wc -l` → `awk -F, '{print NF}'` correction the writer caught the
  hard way) and `test-finalize.sh` (10 asserts covering happy path,
  missing/invalid JSON skips with stderr warnings, `_note`-only as
  empty plus the renderer's empty-prior-day suppression). 9 → 35
  asserts.
- Two-commit release: `d0e35e7` (substantive) + `6b45ff6` (chore).
  Pushed, pulled into global install. Permissions confirmed live.

## What Didn't Work

- **v1.4.0 wasn't actually silent on first run.** The whole point of
  the tool is to feel weightless, and three approval prompts on the
  first invocation broke that. Lesson: when designing a slash command,
  smoke-test the harness friction *before* declaring it shipped, not
  after. The fix was small (≈2h) but should have been caught in plan.
- **The original code-quality reviewer for T1 flagged a "missing curly
  apostrophe in `I've`"** — turns out *I* had introduced that fake
  requirement in my reviewer prompt; the spec/plan/impl all use ASCII
  `'` consistently. Verified with `xxd`. Be careful when telling the
  reviewer what to verify; bad briefs produce false positives.
- **No CI for the per-project Agent prompt.** The bullet-density
  problem can only be caught at smoke-test time because we can't
  golden-test what the model produces. Acceptable, but flag if it
  drifts again.

## Next Steps

Ordered by priority:

1. **Live smoke-test v1.4.1 end-to-end.** Run `/rulez:what-have-i-done`
   in a fresh session — should produce no approval prompts and
   chunkier bullets. If a prompt fires, the script paths or arguments
   drifted from the whitelist; fix that, don't approve through. The
   bullet-density change is judgement-only; if the dc-import day still
   reads like a commit log, tighten the Agent prompt example further
   (e.g., add a second Bad/Good pair for documentation-only days).
2. **Carryovers still valid from v1.3.2 / v1.3.3 handoffs:**
   - Live smoke-test v1.3.1 punt-detection end-to-end (Stop hook →
     triage Agent → slice files disappear → raw files become structured).
   - Wrapper-vs-bare-array fix on `scripts/punts-enrich.sh`
     (still uses `claude -p --output-format json` and emits the
     `{result: "..."}` wrapper; consume the bare array directly).
   - Slice-file accumulation cleanup in `punts-detect.sh`
     (opportunistic `find -mtime +14 -delete`).
   - Test cleanup race carryover from earlier sessions.
   - Auto-update.sh hardening, statusline auto_compact_threshold, etc.
3. **Open follow-ups flagged in the v1.4.0 final review** (none
   merit a v1.4.2):
   - Renderer's outer `for date in $DATES` relies on word-splitting;
     switch to `while IFS= read -r date` for symmetry with the inner
     project loop.
   - Slash command's old `YESTERDAY` reference was removed in v1.4.1
     (`context.sh` still prints it for parity, but the .md no longer
     reads it). Could drop from the script too if the variable stays
     unused after a few cycles.
   - UPGRADE.md "grouped-by-project" vs README "grouped by project
     per day" wording — pick one when next touching either file.
   - Spec/slash-command sentinel divergence: spec says "no git
     activity in window", slash command says "no activity in window".
     Both work because the dispatcher only checks for `_note` presence.

## Key Decisions

- **Brainstorm → spec → plan → subagent-driven for v1.4.0; inline
  patch for v1.4.1.** The full flow is right when there's design
  judgment to lock in (data flow, file decomposition, agent shape).
  v1.4.1 was a tightly-scoped fix with no design forks worth
  brainstorming over — the user gave the direction inline ("wrap
  calls into scripts and whitelist them"). Don't ceremoniously route
  small patches through the full superpowers loop just because the
  big release used it.
- **Per-project bullets are now narrative, not commit-list.** The
  Agent prompt has a worked Bad/Good example so the model has a
  concrete contrast. This is judgment-quality output, not a tested
  property; if it drifts, edit the example, don't write a test.
- **Empty prior-day headings: suppress; today: always print.** The
  asymmetry is intentional. Today's empty markers tell the user
  "yes I checked this project, no it had nothing"; on prior days that
  signal is noise.
- **The slash command never composes heredoc bash.** It is now a
  hard rule for this command (and a good convention for any future
  rulez command): if you'd reach for `cat <<EOF`, write a script
  that takes args, whitelist it, and call it.
- **Per-Agent JSONs land via the Write tool, not bash heredocs.**
  The Write tool doesn't trigger the "expansion obfuscation" guard
  no matter how many braces or quotes the JSON contains. This is the
  pattern any command that needs to ferry multi-line strings into a
  shell pipeline should use.
- **Two-commit release pattern held throughout.** `feat:` /
  `docs:` / `fix:` for substantive changes, then `chore: release
  vX.Y.Z` to bump VERSION + UPGRADE.md.
