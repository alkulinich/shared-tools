# Punts Triage

Walk the accumulated raw punt evidence interactively and promote the worthy
items into curated `.claude/punts/<slug>.md` files (one issue per file,
git-tracked).

## Instructions

1. **List raw evidence files**

```bash
ls -1t .claude/punts/raw/*.json 2>/dev/null
```

If the listing is empty, report `No untriaged punts.` and stop.

2. **Walk each file (oldest first by mtime)**

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

3. **APPROVE → write `.claude/punts/<slug>.md`**

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

4. **REJECT → drop the row**

Remove this row from the raw JSON file. (Rejection is transient — if the
same `id` shows up in a future session, it will be re-presented.)

5. **SKIP → leave the row**

Move on to the next row without modifying the raw JSON.

6. **MERGE WITH `<existing>` → append to the existing `.md`**

Append a new evidence block to the existing `.md`:

```markdown

(also seen in session `<row.session_id>` on branch `<row.branch>` at <row.session_ended_at>)

> <row.evidence_quote>
```

Update the `last_seen` date in the frontmatter to today, and append the
session id to the `sessions:` array. Remove this row from the raw JSON.

7. **Clean up empty raw files**

After processing each raw file, if its rows array is now empty, delete the
file:

```bash
rm .claude/punts/raw/<file>.json
```

8. **Final report**

Summarize: `N approved, M rejected, K skipped, P merged.`

## Notes

- Process rows interactively, one at a time. Do not bulk-approve.
- The user may stop at any point; remaining rows survive in their raw JSON
  for the next triage pass.
- Curated `.md` files are git-tracked; ask the user whether to commit them
  at the end of the session.
