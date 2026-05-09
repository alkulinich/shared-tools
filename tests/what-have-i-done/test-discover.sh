#!/usr/bin/env bash

test_discover_emits_valid_dedupes_skips() {
  # Build a fake projects root.
  local root
  root=$(make_temp_projects_root)

  # Build two real cwd targets (so existence check passes).
  local cwd_a cwd_b
  cwd_a=$(mktemp -d -t whidtest-real-A.XXXXXX)
  cwd_b=$(mktemp -d -t whidtest-real-B.XXXXXX)

  # Subdir 1: valid; cwd_a.
  add_project_dir "$root" "-Users-rulez-projA"      "{\"cwd\": \"$cwd_a\"}"
  # Subdir 2: jsonl missing cwd.
  add_project_dir "$root" "-Users-rulez-projB"      '{"foo": "bar"}'
  # Subdir 3: cwd points to a non-existent path.
  add_project_dir "$root" "-Users-rulez-projC"      '{"cwd": "/tmp/whidtest-does-not-exist-xyz"}'
  # Subdir 4: temp-dir prefix; must be filtered.
  add_project_dir "$root" "-private-var-folders-xx" "{\"cwd\": \"$cwd_b\"}"
  # Subdir 5: dedupe — same cwd as subdir 1.
  add_project_dir "$root" "-Users-rulez-projA-worktree" "{\"cwd\": \"$cwd_a\"}"
  # Subdir 6: empty (no jsonl).
  mkdir -p "$root/-Users-rulez-projD"

  touch_recent "$root"

  local out
  out=$(WHID_PROJECTS_DIR="$root" \
    bash "$SCRIPTS_DIR/what-have-i-done-discover.sh" 7 2>/dev/null || true)

  assert_contains "$cwd_a" "$out" "valid project's real cwd is emitted"
  assert_not_contains "$cwd_b" "$out" "/private/var/... project is filtered"
  assert_not_contains "/tmp/whidtest-does-not-exist-xyz" "$out" \
    "non-existent cwd is skipped"
  # Dedupe: cwd_a appears exactly once.
  local count
  count=$(printf '%s\n' "$out" | grep -cF "$cwd_a" || true)
  assert_eq "1" "$count" "duplicate cwd is deduped (appears once)"

  # Cleanup.
  rm -rf "$root" "$cwd_a" "$cwd_b"
}
