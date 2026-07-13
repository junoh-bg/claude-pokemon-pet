#!/bin/bash
# Runs every tests/test-*.sh; exits non-zero if any fail.
cd "$(dirname "$0")" || exit 1
rc=0
for t in test-*.sh; do bash "$t" || rc=1; done
[ "$rc" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$rc"
