#!/bin/bash
. "$(dirname "$0")/lib.sh"

setup
"$CORE" event thinking </dev/null >/dev/null
assert_eq "state written" "thinking 1789300000" "$(cat "$CACHE/state")"

"$CORE" event done </dev/null >/dev/null
assert_eq "task counted" "2026-07-13 1" "$(cat "$CACHE/tasks")"
"$CORE" event done </dev/null >/dev/null
assert_eq "task counted twice" "2026-07-13 2" "$(cat "$CACHE/tasks")"
assert_eq "streak starts at 1" "2026-07-13 1" "$(cat "$CACHE/streak")"
teardown

setup  # streak continues from yesterday
echo "2026-07-12 3" > "$CACHE/streak"
"$CORE" event done </dev/null >/dev/null
assert_eq "streak continues" "2026-07-13 4" "$(cat "$CACHE/streak")"
teardown

setup  # streak resets after a gap
echo "2026-07-10 9" > "$CACHE/streak"
"$CORE" event done </dev/null >/dev/null
assert_eq "streak resets" "2026-07-13 1" "$(cat "$CACHE/streak")"
teardown

setup  # stale tasks file from another day resets
echo "2026-07-12 7" > "$CACHE/tasks"
"$CORE" event done </dev/null >/dev/null
assert_eq "stale tasks reset" "2026-07-13 1" "$(cat "$CACHE/tasks")"
teardown

setup  # care mistakes via PostToolUseFailure payloads
"$CORE" event mistake < "$ROOT/tests/fixtures/posttoolusefailure-error.json" >/dev/null
assert_eq "mistake counted" "2026-07-13 1" "$(cat "$CACHE/mistakes")"
assert_eq "mistake sets working state" "working 1789300000" "$(cat "$CACHE/state")"
"$CORE" event mistake < "$ROOT/tests/fixtures/posttoolusefailure-interrupt.json" >/dev/null
assert_eq "user interrupt not counted" "2026-07-13 1" "$(cat "$CACHE/mistakes")"
"$CORE" event working < "$ROOT/tests/fixtures/posttooluse-ok.json" >/dev/null
assert_eq "working never counts a mistake" "2026-07-13 1" "$(cat "$CACHE/mistakes")"
"$CORE" event mistake </dev/null >/dev/null
assert_eq "bare mistake event still counts" "2026-07-13 2" "$(cat "$CACHE/mistakes")"
"$CORE" event mistake <<< 'not json at all' >/dev/null
assert_eq "garbage payload still counts" "2026-07-13 3" "$(cat "$CACHE/mistakes")"
teardown

setup  # concurrent done events must not lose task increments (reviewed race)
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do "$CORE" event done </dev/null >/dev/null & done
wait
assert_eq "20 concurrent dones all counted" "2026-07-13 20" "$(cat "$CACHE/tasks")"
for i in 1 2 3 4 5; do "$CORE" event mistake < "$ROOT/tests/fixtures/posttoolusefailure-error.json" >/dev/null & done
wait
assert_eq "5 concurrent mistakes all counted" "2026-07-13 5" "$(cat "$CACHE/mistakes")"
teardown

setup  # the hook path must never fail or emit noise, whatever the state
echo 'not json' > "$CACHE/partner"
err="$("$CORE" event thinking </dev/null 2>&1 >/dev/null)"; rc=$?
assert_eq "event exits 0 despite broken cache" "0" "$rc"
assert_eq "event emits no stderr noise" "" "$err"
assert_eq "state still written" "thinking 1789300000" "$(cat "$CACHE/state")"
teardown

report
