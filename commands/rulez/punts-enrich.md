# Punts Enrich

Promote regex-only punt evidence into structured rows by spawning the
extraction subagent against each captured slice. Idempotent — running it
when everything is already structured is a no-op.

## Instructions

1. **Run the enrich script** from the project root:

```bash
~/.claude/skills/rulez-claudeset/scripts/punts-enrich.sh
```

2. **Report the summary line to the user.** It looks like:

```
punts-enrich: processed=N enriched=M failed=K skipped_no_slice=S already_structured=A
```

3. **If `failed > 0`**, suggest the user re-run later (most failures are
   transient — `claude -p` rate-limit hiccups, network blips). The raw +
   slice files are preserved for retry.

4. **If `skipped_no_slice > 0`**, those raw files are stuck as regex-only
   forever (the slice was deleted before enrichment). The user can still
   triage them on the regex evidence alone.

5. **After successful enrichment**, suggest `/rulez:punts-triage` to walk
   the structured rows.

## Notes

- Auto-invoked at the top of `/rulez:punts-triage`, so most users will
  never call this directly. Useful for batch back-fills or after long
  offline periods.
- Requires `claude` on `PATH`. If unavailable, the script exits silently
  with no work done.
