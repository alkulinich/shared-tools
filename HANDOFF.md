# Handoff

## Task

Make the punt-detection Stop hook viable on long-running sessions. The v1.2.0 implementation worked for fresh sessions but had three latent failure modes that surfaced this session: (1) full-transcript re-screen on every Stop fire, (2) subagent context overflow on multi-megabyte transcripts, (3) silent acceptance of truncated/malformed `claude -p` output. Plus a small clarity gap: the prompt builder still talked about "the transcript" after we switched to slice files. Resolved across four patch releases (v1.2.1 → v1.2.4).

## Current State

- **Branch:** `main`, in sync with `origin/main`.
- **Released as v1.2.4.** Global install at `~/.claude/skills/rulez-claudeset/` is at v1.2.4 (verified via the final `/rulez:update-claudeset` invocation).
- **Tests:** `bash tests/punts/run-tests.sh` — 24/24 pass. Test count grew across releases: 16 (v1.2.0) → 20 (v1.2.1) → 23 (v1.2.2) → 24 (v1.2.4).
- **Files modified this session** (cumulatively across the four releases):
  - `scripts/punts-detect.sh` — incremental offset, slice + chunk, JSON validation.
  - `scripts/punts-extract-prompt.sh` — variable rename + slice-aware wording.
  - `tests/punts/helpers.sh` — `read_offset`, `wait_for_jq_value`, `count_raw_files`, `find_raw_file`.
  - `tests/punts/test-detect.sh` — 8 new test functions.
  - `VERSION` — 1.2.0 → 1.2.4.
  - `UPGRADE.md` — four new sections at top.
- **Untracked:** `tmp/` (pre-existing, not part of this work).

## What Worked

### v1.2.1 — Byte-offset checkpoint (commits `6ae3543` + `0702125`)

- Brainstormed 5 options (byte offset / line count / UUID marker / tail-N / latest-turn-only); user picked Shape A (per-run files) + Option 1 (byte offset).
- Plan written to `/Users/rulez/.claude/plans/declarative-wiggling-ritchie.md`, approved via ExitPlanMode.
- State file at `.claude/punts/state/<sid>.offset` (single integer). Shrinkage detection for compaction. Atomic write via `.tmp` + `mv`. Filename suffix uses `new_offset` zero-padded + `$$` PID.
- Synchronous regex-only fallback written before subagent fork — lost-evidence guarantee.
- Tests added: `test_offset_state_written_after_run`, `test_no_new_bytes_writes_nothing`, `test_new_bytes_written_only_for_new_window`, `test_shrinkage_resets_offset`.

### v1.2.2 — Slice + chunk (commits `11aee68` + `84700bf`)

- User reported the real failure: a 5.5 MB / 382-match transcript blew the subagent's context. Diagnosis: even after v1.2.1, the prompt still said "Read the transcript at $transcript_path" — the FULL file. Slicing solved steady-state; chunking solved the backlog/single-pathological-turn case.
- Plan: slice the new byte window to `.claude/punts/state/slice-<sid>-<chunk_end>-<pid>.jsonl` with 4 KB lookback; chunk windows > `PUNT_MAX_CHUNK` (default 256 KB); fan out one detached `claude -p` per chunk, **serial within a single backgrounded subshell** (cost is fine but rate limits aren't).
- Subtle bug caught and fixed mid-implementation: with `LOOKBACK > chunk_start`, the slice for chunk N+ would overlap chunk 0's content and the per-chunk regex screen would double-count. Solution: separate read for the slice (with lookback) vs. per-chunk regex screen (chunk-only bytes).
- Second subtle bug: `tail -n +2` was wrongly dropping the first whole line when `chunk_start` happened to land on a line boundary (the steady-state case where `stored_offset = end-of-line`). Solution: `read_window` helper with prev-byte check — leverages bash's command-substitution-strips-trailing-newlines so an empty `prev` means the prior byte was `\n`.
- Tests added: `test_chunking_produces_multiple_raw_files`, `test_subagent_receives_slice_path_not_full_transcript`, `test_slice_files_cleaned_up`. Existing `test_subagent_writes_structured_json` updated to use `wait_for_jq_value` (poll for the structured shape, not just file existence — synchronous fallback now writes the file before subagent overwrites).

### v1.2.3 — Prompt-builder clarity (commits `dd4a591` + `936165e`)

- After v1.2.2 the prompt builder still called its arg `transcript_path` and told the subagent to "Read the transcript at …" even though it was now receiving a chunk slice. Subagent could over-rate confidence on phrases that look new because it doesn't know the bytes before the slice are intentionally clipped.
- Renamed `transcript_path` → `slice_path`. Reworded the prompt to "Read the transcript slice at …" + a sentence about the byte-range scope. Annotated `session_ended_at` to note it's the Stop-hook fire time, not original message wall-clock (matters during backlog drains).
- Pure cosmetic — schema unchanged, all 23 tests green without modification (the rename is positional-arg-transparent).

### v1.2.4 — JSON validation (commits `c97bff8` + `51e61ef`)

- User asked "should we add check of the data returned by spawned claude? at least is it valid json?". Answer: yes. A 0 exit with truncated stdout is the failure mode that bit them on the 5 MB session pre-v1.2.2 — exit code says success, but the file on disk is garbage that triage can't parse.
- One-line fix: chain `&& jq -e . "$out_file.tmp" >/dev/null 2>&1` after the `claude -p` invocation. On parse failure, `rm -f $out_file.tmp` and the synchronous regex-only fallback survives.
- Test added: `test_invalid_subagent_output_falls_back_to_regex` — fake claude that exits 0 but emits `this is not valid json {{{`; assertion verifies `.fallback == "regex-only"` survives.

### Process notes

- All four releases used the established two-commit pattern: `feat`/`fix`/`perf`/`docs` + separate `chore: release vX.Y.Z`. Clean bisect.
- Commit messages all written via `Write` tool to `/tmp/cc-msg-*.txt` then `git commit -F` — sidesteps the heredoc-quoting bug from prior sessions.
- After each release: `git push origin main` → `git -C ~/.claude/skills/rulez-claudeset pull --ff-only` → `bin/setup -q` → verify VERSION bump.

## What Didn't Work

- **`tail -n +2` everywhere bug** — initially I applied it unconditionally to drop "partial first line" of mid-stream byte windows. Broke `test_new_bytes_written_only_for_new_window` because in steady state `chunk_start` IS a line boundary (post-incremental, `stored_offset` is always `wc -c` = end of file = end of line). The dropped-first-line was actually a whole new line containing the punt phrase. Fixed by introducing `read_window` helper that checks the prev byte before deciding whether to trim.

- **Test infrastructure noise: `Killed: 9` lines in test output** during v1.2.4. Backgrounded fake-claude processes from one test getting cleaned up after the next test starts. Pre-existing race — tests still all pass; ignored as noise. [PUNT]: improve test cleanup to wait on backgrounded subshells before tearing down `$proj`.

- **Pre-existing wrapper-vs-bare-array shape mismatch** still unresolved. `claude -p --output-format json` returns a wrapper `{"type":"result","result":"<json string>",...}` but the triage command (`commands/rulez/punts-triage.md`) reads files as if they were the bare array. Tests bypass the wrapper via fake claude binaries that emit bare arrays directly, so the bug is masked. [PUNT]: not addressed in this session — separate change, separate release. Tier-3 JSON validation (`.result | fromjson | type == "array"`) was deliberately skipped in v1.2.4 for the same reason.

## Next Steps

1. **Live smoke-test v1.2.4 end-to-end** — end an active session that includes punt phrasing in this very repo. Inspect `<repo>/.claude/punts/state/<sid>.offset` (matches `wc -c < transcript`?), `<repo>/.claude/punts/raw/<sid>-*-*.json` (correct shape? per-chunk if window was big?), and `<repo>/.claude/punts/state/slice-*` (should be empty after subshell finishes).

2. **Try `/rulez:punts-triage`** on accumulated raw evidence (this session may have produced some via the live hook). Will surface the wrapper-vs-bare-array bug if real `claude -p` was actually invoked.

3. **Reconcile the wrapper-vs-bare-array shape** ([PUNT] above) — either:
   - update `punts-detect.sh` to unwrap `.result` and write the bare array, or
   - update `commands/rulez/punts-triage.md` (and tests' fake-claude payloads) to expect the wrapper.

   Probably the former — keeps the on-disk shape simple and triage doesn't need to know about claude-p internals. Would also enable tier-2/3 JSON validation in detect.sh.

4. **Test cleanup race** ([PUNT] above) — backgrounded subshells in tests should be awaited before `rm -rf $proj`. Cosmetic noise; low priority.

5. **Carryovers from prior sessions** (still relevant):
   - auto-update.sh failure marker hardening
   - set-current-command.sh hardening
   - `/rulez:todo` smoke test
   - `/effort max` chip smoke test
   - watch claude-code#43989 for `auto_compact_threshold` exposure (would replace the hardcoded 400k in `scripts/statusline.sh`).

## Key Decisions

- **Shape A + byte offset** (over JSONL append, per-claim sharding, line-count, etc.). Simpler to reason about, no merge logic, dedup happens at triage time by claim `id` (sha1).

- **Serial within a single detached subshell** for chunk fan-out (vs. parallel-with-cap). User said "I don't care about costs" — but rate limits ≠ costs. A 22-chunk parallel storm would 429-burst all chunks simultaneously, defeating the point. Serial inside `( ... ) & disown` keeps the UI unblocked AND avoids the storm.

- **Validate JSON, don't validate shape** (tier 1, not tier 3). The `.result | fromjson | type == "array"` check would have failed in production where the real wrapper exists, while passing in tests where fakes emit bare arrays. Catch the most likely failure (truncation) without committing to either shape.

- **Per-chunk regex screen restricted to chunk's own bytes**, never lookback. Otherwise hits inside the lookback would be double-counted by both the current and previous chunk's screens.

- **State advance happens before the subagent fork**. Subagent runs detached; we can't wait on it. Persisting offset eagerly means subagent failure costs us evidence enrichment, but the synchronous regex-only fallback already on disk preserves the hits themselves.

- **Two-commit release pattern preserved** across all four releases — `fix`/`perf`/`docs` then `chore: release`. Bisect-friendly.

- **`PUNT_MAX_CHUNK` and `PUNT_LOOKBACK` exposed as env vars** — not just for tuning, but because tests need to lower MAX_CHUNK to exercise multi-chunk paths without generating multi-MB fixtures.

- **Tier-3 validation deferred, not skipped forever** — when (3) above is resolved, revisit `jq -e '.result | fromjson | type == "array"'` to catch wrapper-with-non-array result content.
