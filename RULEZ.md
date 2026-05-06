# RULEZ

Global rules applied to all projects via rulez-claudeset.

## Compact Instructions

When compressing, preserve in priority order:
- Architecture decisions (NEVER summarize)
- Modified files and their key changes
- Current verification status (pass/fail)
- Open TODOs and rollback notes
- Tool outputs (can delete, keep pass/fail only)

## Punts

When you decide an issue is out-of-scope, pre-existing, or otherwise should
not be addressed in the current change, prefer to flag it on its own line as:

    [PUNT]: <one-line description of what was observed and where>

Use this only for genuine observations you are choosing not to act on, not for
neutral references (e.g. "the pre-existing tests pass" is not a punt).
Captured punts can be reviewed later via `/rulez:punts-triage`.
