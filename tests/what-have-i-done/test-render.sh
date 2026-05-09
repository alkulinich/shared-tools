#!/usr/bin/env bash

test_render_matches_golden() {
  local actual
  actual=$(bash "$SCRIPTS_DIR/what-have-i-done-render.sh" "2026-05-09" \
    < "$FIXTURES_DIR/render-input.json")
  local golden
  golden=$(cat "$FIXTURES_DIR/render-golden.md")
  assert_eq "$golden" "$actual" "renderer output matches golden file"
}

test_render_omits_empty_prior_day_project() {
  local actual
  actual=$(bash "$SCRIPTS_DIR/what-have-i-done-render.sh" "2026-05-09" \
    < "$FIXTURES_DIR/render-input.json")
  local yesterday_section
  yesterday_section=$(printf '%s' "$actual" | awk '/^## Yesterday/{f=1;next} /^## /{f=0} f')
  assert_contains "26.03-shared-tools" "$yesterday_section" \
    "yesterday section names the shared-tools project"
  assert_not_contains "0current-work" "$yesterday_section" \
    "yesterday section omits empty 0current-work project"
}

test_render_shows_no_activity_for_today_empty_project() {
  local actual
  actual=$(bash "$SCRIPTS_DIR/what-have-i-done-render.sh" "2026-05-09" \
    < "$FIXTURES_DIR/render-input.json")
  local today_section
  today_section=$(printf '%s' "$actual" | awk '/^## Today/{f=1;next} /^## /{f=0} f')
  assert_contains "0current-work" "$today_section" \
    "today section keeps 0current-work even when empty"
  assert_contains "(no git activity in window)" "$today_section" \
    "today section flags empty project with no-activity note"
}
