# Push Fixes

Add fixes to the current branch and push to remote.

The drafting work (`git status`, `git diff`, deciding the commit
message and file list) runs inside an Agent-tool subagent so the diff
never enters the main thread. Main thread sees only the proposed
commit block.

## Instructions

1. **Capture project root and dispatch the fix-drafter Agent.**

   Set `PROJECT_ROOT=$(pwd)`. Use the **Agent tool** with
   `subagent_type: "general-purpose"`. Pass the prompt body below
   verbatim, substituting `<project_root>`:

   ```
   You are drafting a fix commit for the current branch.
   Operate inside <project_root>.

   Steps:
   1. cd "<project_root>"
   2. Run: git branch --show-current
   3. Run: git status --porcelain
   4. Run: git diff
   5. Decide:
        - commit_message: conventional-commit style (fix: / chore: /
                          docs: / refactor: / style:). Imperative.
                          ≤ 70 chars. Use fix: when the diff actually
                          fixes something.
        - files:          specific paths from `git status` (avoid
                          `git add .` shape).
        - on_main:        true if the current branch is "main" or
                          "master". false otherwise.

   Return a single JSON object, no prose, no code fences:
     {
       "branch":         "feature/...",
       "files":          ["a.ts", "b.ts"],
       "commit_message": "fix: correct validation logic",
       "on_main":        false
     }
   ```

2. **Validate, retry, fall back.**

   - Extract the first balanced `{ ... }` block from the Agent's final
     message.
   - Validate with `printf '%s' "$json" | jq -e . >/dev/null`.
   - On parse failure: dispatch ONE retry Agent with the same prompt.
   - On second failure: print
     `(Agent dispatch failed for fix-drafter, falling back to inline)`
     and run steps 1.1–1.5 directly in the main thread.

3. **Verify we're not on main.** If the JSON's `on_main` is true, warn
   the user and suggest using `/rulez:create-pr` instead. Stop here —
   do not proceed.

4. **Render the proposed commit block** from the JSON:

```
## Push Fixes to Current Branch

**Branch:** `<branch>`
**Files:**
- <file 1>
- <file 2>

**Commit message:**
<commit_message>
```

5. **Ask user to confirm or edit** using AskUserQuestion with options:
   - "Push fixes" (proceed)
   - "Edit files" (modify file list — main thread edits the JSON
     in-place, no re-dispatch)
   - "Edit message" (modify commit message — same)
   - "Cancel"

6. **On confirmation**, execute the script:
```bash
~/.claude/skills/rulez-claudeset/scripts/git-push-fixes.sh "<commit_message>" <files...>
```

## Example Execution

```bash
~/.claude/skills/rulez-claudeset/scripts/git-push-fixes.sh \
  "fix: move rollback script to separate directory" \
  database/migrations/001_initial_schema_down.sql \
  database/rollbacks/001_rollback.sql
```

## Use Cases

- Addressing PR review feedback
- Fixing issues found during testing
- Adding forgotten files to a PR
- Small corrections before merge
