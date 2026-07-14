#!/bin/bash
# Harness wrapper for the Python unit tests (skips cleanly if python3 absent).
cd "$(dirname "$0")" || exit 1
command -v python3 >/dev/null || { echo "-- test-python.sh: SKIP (no python3)"; exit 0; }
rc=0
for m in test_gif test_png test_term; do
    [ -f "$m.py" ] || continue
    python3 -m unittest -q "$m" || rc=1
done
echo "-- test-python.sh: $([ $rc -eq 0 ] && echo 'pass' || echo 'FAIL')"
exit $rc
