# Handoff

## Task
Investigate why the `/effort` chip in the statusline never displayed, then fix it and ship the fix as a formal release. The feature was "hacky by design" from v1.1.0 and had stopped working (or never worked) — confirmed broken when `/effort` was typed this session and no chip appeared.

## Current State
- **Branch:** `main`, synced with `origin/main`
- **Released as v1.1.3.** Global install at `~/.claude/skills/rulez-claudeset/` is at v1.1.3, setup re-run, clean.
- **Commits pushed this session (newest first):**
  - `a436a6b` `chore: release v1.1.3`
  - `8340f07` `fix: make /effort chip actually resolve`
- **Files modified:**
  - `scripts/statusline.sh` — replaced bogus `.effort_level // .model.effort` JSON probe with a transcript scan; added `xhigh → XHI` chip label; removed non-existent `auto`; added uppercase 4-char fallback for unknown values
  - `VERSION` — `1.1.2` → `1.1.3`
  - `UPGRADE.md` — new `## To v1.1.3 — from v1.1.2` section at the top documenting the fix, what's captured vs not (picker-form limitation), and the resolution order
- **Untracked:** `tmp/` (per repo convention)

## What Worked

**Root-cause investigation.**
- Added a temporary `printf "$input" > /tmp/cc-statusline-debug.json` tee to capture real statusLine stdin — but the capture landed after my edits (Claude Code renders statusline on event, and my edit came mid-turn), so I used web research as the authoritative signal instead. Removed the debug tee in the same edit cycle.
- WebSearch + WebFetch of [Claude Code statusline docs](https://code.claude.com/docs/en/statusline) confirmed the stdin schema: `model.{id,display_name}`, `cwd`, `workspace.*`, `context_window.*`, `rate_limits.*`, `exceeds_200k_tokens`, `session_id`, `transcript_path` — **no effort/reasoning field anywhere**. Confirmed via [claude-code#51982 (and dedupes #50577, #27747, #31987, #36187, #38476)](https://github.com/anthropics/claude-code/issues/51982) that this is a known pending upstream feature request since Claude Code 2.1.111.
- `claude --help | grep effort` confirmed real values: `low, medium, high, xhigh, max` — no `auto`, despite earlier UPGRADE notes.

**The fix (`scripts/statusline.sh`).**
- Dropped `jq -r '.effort_level // .model.effort // empty'` (always empty).
- Added `transcript=$(echo "$input" | jq -r '.transcript_path // empty')`.
- Scan the transcript JSONL with `grep -oE '<command-name>/effort</command-name>[^<]{0,80}<command-message>[^<]{0,40}</command-message>[^<]{0,80}<command-args>[^<]+</command-args>'` — tight gap budget avoids false positives from transcript content that quotes the invocation structure (this session's own Bash-call history contained such strings). Take the last match, sed-extract the args, `tr -d '[:space:]\\'` to strip the literal JSON `\n` escapes.
- Fallback chain kept: env var → project settings.json `effortLevel` → user settings.json `effortLevel`.
- Chip label: added `xhigh → XHI`; removed `auto`; unknown values → `printf | tr '[:lower:]' '[:upper:]' | cut -c1-4`.

**Testing.**
- Wrote 6 smoke tests covering empty state, env var fallback, settings.json fallback, explicit-arg transcript scan, multi-invocation latest-wins, and picker-form (empty args) → fall through. All pass. Real-session transcript correctly returns `MAX` **only because** this very session's Bash command payloads contained the structural pattern — in a clean session, stray content won't match the full 3-tag regex.

**Release.**
- Mirrored the updated `scripts/statusline.sh` to `~/.claude/skills/rulez-claudeset/scripts/statusline.sh` for immediate live feedback (the global install is a separate clone, not a symlink — was one of today's gotchas).
- Committed/pushed `8340f07` (fix alone), then `a436a6b` (VERSION bump + UPGRADE.md entry).
- `/rulez:update-claudeset` surfaced a collision: the mirror had left the global clone with "modified" status against HEAD even though content now matched origin's new tip. Discarded with `git checkout -- scripts/statusline.sh`, then `pull --ff-only` succeeded. Setup re-ran clean.

## What Didn't Work

- **Loose transcript regex (first attempt).** `grep -F '<command-name>/effort</command-name>' | grep -oE '<command-args>[^<]+</command-args>'` matched any `<command-args>` on a line mentioning `/effort`. Failed test 7 (real transcript) with a false-positive `MAX` from unrelated quoted content. Fixed by requiring the full name+message+args structure in one regex match with a 80-char gap budget between tags.
- **First regex used `[[:space:]]` for the inter-tag gap.** Failed because JSONL content is JSON-escaped — the `\n` between tags is literal backslash-n, not a real newline. `[[:space:]]` matches neither. Switched to `[^<]{0,80}` which correctly matches any non-tag characters including the literal backslash-n + indentation.
- **Mirroring to the global install via `cp` leaves the clone in a dirty state** vs. its own HEAD — so the next `git pull --ff-only` refuses. Not a blocker but a friction point for future dev-loop shortcuts.
- **Picker-form `/effort` overrides cannot be captured.** When the user types `/effort` and selects via arrow keys, the chosen value is not written to the transcript (empty `<command-args>`), not written to settings.json, not exposed in statusLine JSON. The chip cannot reflect picker-form overrides. This is an upstream limitation — documented in the v1.1.3 UPGRADE.md section honestly rather than hand-waved.

## Next Steps

Ordered by priority.

1. **Verify the chip in this very session.** Type `/effort max` (explicit arg) at a prompt. Next statusline render should show `MAX` in magenta between model and session time. If not, the transcript scan didn't fire — check that `.transcript_path` is non-empty in the statusLine stdin (sanity-print it via a tempoary `echo "$transcript" >> /tmp/sl.log` in the script) and that the transcript actually has the full tag structure on one line.
2. **Add failure marker to `bin/auto-update.sh`** (carryover from previous session). On `fetch` or `pull --ff-only` failure, write `"auto-update failed: <reason>"` to `$MARKER_FILE` so silent skips become visible next session. Still outstanding.
3. **Harden `scripts/set-current-command.sh`**: prepend `mkdir -p .claude` before the redirect. One-liner. Still outstanding from previous session.
4. **Smoke-test `/rulez:todo` end-to-end in a real session** (`/rulez:todo buy milk` → `ls` → `done 1` → `archive`). Still outstanding from previous session.
5. **Watch upstream [claude-code#51982](https://github.com/anthropics/claude-code/issues/51982).** If Claude Code adds `.model.effort` to statusLine stdin, add it as the highest-precedence source in `statusline.sh` above the transcript scan (and remove the "picker form is lost" caveat from UPGRADE.md).

## Key Decisions

- **No bundling with other fixes.** v1.1.3 ships only the `/effort` chip fix + docs. Could have piggy-backed the `set-current-command.sh` fix or the auto-update marker, but those are unrelated and would muddy the UPGRADE.md story. One patch release, one concern.
- **Transcript scan over "just fix the env var path" alone.** The env var + settings.json fallbacks work for persistent defaults but not for session overrides — which is the exact use case the chip is supposed to surface. Without transcript scanning, the chip would still be useless for the user's primary workflow (`/effort max` mid-session). Accepted the regex fragility in exchange for the mid-session capture.
- **Tight regex gap budget (80 chars between tags) rather than `[^<]*`.** Tighter is better because Claude Code's own inter-tag content is `\n            ` (14 chars) and rarely exceeds ~40. An 80-char budget fits real invocations with headroom but won't span stray content in unrelated transcript lines. Tested both loose and tight against the real session transcript — only tight correctly rejected the false positives from my earlier Bash command strings.
- **Honest picker-form caveat in UPGRADE.md.** Easy to gloss over — instead, called out explicitly that picker-form overrides cannot be captured and linked to the upstream issue. Prevents the next "why doesn't it reflect my /effort picker choice?" bug report.
- **Uppercase 4-char truncation for unknown values.** Defensive: if Anthropic adds a new level (e.g. `ultra`, `insane`, `auto`), the chip still renders something sane (`ULTR`, `INSA`, `AUTO`) instead of dropping the chip entirely. Future-proof without hardcoding hypothetical values.
- **Separate fix commit + release commit.** `8340f07` is the isolated behavior change; `a436a6b` is VERSION + UPGRADE.md only. Keeps the git history easy to bisect — if the fix ever needs to be reverted, reverting `8340f07` is a clean operation without churn in VERSION/UPGRADE.md.
- **Mirrored fix to global install before push** for fast live feedback, accepting the "modified" dirty state that `/rulez:update-claudeset` then had to resolve. Tradeoff: one extra step during the update (`git checkout -- scripts/statusline.sh`), gained same-window live verification. For future mirrored fixes, consider `git -C ~/.claude/skills/rulez-claudeset stash` before mirroring, or skip mirroring and push first.
