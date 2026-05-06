# Punts Triage

Walk the accumulated raw punt evidence interactively and promote the worthy
items into curated `.claude/punts/<slug>.md` files (one issue per file,
git-tracked).

## Instructions

1. **Enrich any regex-only evidence first** (in-session, via Agent tool)

Stop hooks capture only regex-only fallback rows; subagent enrichment
runs at triage time. Use the **Agent tool** from inside this session
— fresh subagent per slice, dispatched in parallel — instead of
shelling out to `claude -p`.

a. List regex-only raw files: walk `.claude/punts/raw/*.json` and keep
   the ones whose `.fallback` field equals `"regex-only"`
   (`jq -r '.fallback'`). If none exist, skip the rest of this step
   silently and proceed to step 2.

b. For each one, locate the matching slice at
   `.claude/punts/state/slice-<basename>.jsonl` (where `<basename>` is
   the raw file name minus `.json`). If the slice is missing, count
   that file as `skipped_no_slice` and move on.

c. Read `session_id` and `regex_hits` from the raw file via `jq -r`.

d. Build the extraction prompt for each (slice, session_id, regex_hits)
   triple by running:

   ```bash
   bash ~/.claude/skills/rulez-claudeset/scripts/punts-extract-prompt.sh \
       "$slice" "$session_id" "$regex_hits"
   ```

   Capture the stdout — that's the prompt body for the Agent.

e. Dispatch one **Agent** per file, **all in a single message** so the
   tool calls run in parallel. Use `subagent_type: "general-purpose"`
   and pass the prompt body from step (d) verbatim. Cap parallelism at
   **8 per round**; if there are more, do successive rounds. If the
   backlog is large (more than ~24 files), tell the user and offer to
   run `scripts/punts-enrich.sh` (sequential, no per-round wait, but
   uses `claude -p` and incurs separate billing artifacts) instead.

f. For each Agent's final message: extract the JSON array (the prompt
   instructs the subagent to return "a single JSON array"; look for
   the first `[ ... ]` block). Validate with `jq -e .`. On success,
   overwrite the raw file with that array and `rm` the slice file. On
   failure (malformed JSON, missing slice mid-flight, Agent error),
   leave both the raw file (still regex-only) and the slice in place
   for retry.

g. Report a one-line summary to the user:
   `enriched=N failed=M skipped_no_slice=K already_structured=L`.

> The script `scripts/punts-enrich.sh` and the `/rulez:punts-enrich`
> slash command remain available for batch / non-interactive
> back-fills (cron, scripted drains). Triage uses Agents because
> they share this session's cache and let the main flow parse JSON
> directly without the `claude -p --output-format json` wrapper.

2. **List raw evidence files**

```bash
ls -1t .claude/punts/raw/*.json 2>/dev/null
```

If the listing is empty, report `No untriaged punts.` and stop.

3. **Walk each file (oldest first by mtime)**

For each `*.json` file, read it and iterate the array of evidence rows.

For each row, present to the user:

- **Claim:** `<row.claim>`
- **Evidence:** `> <row.evidence_quote>`
- **Files mentioned:** `<row.files_mentioned>`
- **Source / confidence:** `<row.source> / <row.subagent_confidence>`
- **Seen in:** session `<row.session_id>` on `<row.branch>` at `<row.session_ended_at>`

Then ask: **APPROVE / REJECT / SKIP / MERGE WITH `<existing>`**.

Before APPROVE, check whether a `.claude/punts/*.md` already exists with a
matching `id` (frontmatter). If so, offer MERGE instead.

4. **APPROVE → write `.claude/punts/<slug>.md`**

- Generate a kebab-case slug from `claim`, lowercase, ≤ 64 chars, hyphens only.
- If `<slug>.md` already exists with a different id, append `-2`, `-3`, etc.
- Write the file with this template:

```markdown
---
id: <row.id>
first_seen: <row.session_ended_at YYYY-MM-DD>
last_seen: <row.session_ended_at YYYY-MM-DD>
branches: [<row.branch>]
sessions: [<row.session_id>]
status: open
source: <row.source>
confidence: <row.subagent_confidence>
---

# <claim as title>

## Evidence

> <row.evidence_quote>

(seen in session `<row.session_id>` on branch `<row.branch>` at <row.session_ended_at>)

## Files

- <each file from row.files_mentioned, one per bullet>

## Suggested next step

<ask the user what they want to do about it; record their answer here, or
your own concise recommendation if they say "you decide">
```

Then remove this row from the raw JSON file.

5. **REJECT → drop the row**

Remove this row from the raw JSON file. (Rejection is transient — if the
same `id` shows up in a future session, it will be re-presented.)

6. **SKIP → leave the row**

Move on to the next row without modifying the raw JSON.

7. **MERGE WITH `<existing>` → append to the existing `.md`**

Append a new evidence block to the existing `.md`:

```markdown

(also seen in session `<row.session_id>` on branch `<row.branch>` at <row.session_ended_at>)

> <row.evidence_quote>
```

Update the `last_seen` date in the frontmatter to today, and append the
session id to the `sessions:` array. Remove this row from the raw JSON.

8. **Clean up empty raw files**

After processing each raw file, if its rows array is now empty, delete the
file:

```bash
rm .claude/punts/raw/<file>.json
```

9. **Final report**

Summarize: `N approved, M rejected, K skipped, P merged.`

## Notes

- Process rows interactively, one at a time. Do not bulk-approve.
- The user may stop at any point; remaining rows survive in their raw JSON
  for the next triage pass.
- Curated `.md` files are git-tracked; ask the user whether to commit them
  at the end of the session.
