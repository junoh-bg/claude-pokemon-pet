#!/bin/bash
# Test helpers. Each test runs against a throwaway HOME so the real
# cache is never touched. Source this, then: setup … asserts … teardown; report
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/scripts/pet-core.sh"
PASSES=0 FAILS=0

setup() {
    export HOME="$(mktemp -d)"
    export CACHE="$HOME/.cache/claude-pokemon-pet"
    mkdir -p "$CACHE"
    export PET_TODAY="2026-07-13" PET_YESTERDAY="2026-07-12" PET_NOW="1789300000"
    export PET_LANG="en"   # hermetic: don't let the host system language leak in
    unset PET_SEED 2>/dev/null || true
}
teardown() { rm -rf "$HOME"; }

assert_eq() { # <label> <expected> <actual>
    if [ "$2" = "$3" ]; then PASSES=$((PASSES + 1)); else
        FAILS=$((FAILS + 1))
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}
assert_json() { # <label> <file> <jq-filter> <expected>
    assert_eq "$1" "$4" "$(jq -r "$3" "$2" 2>&1)"
}
report() { printf -- '-- %s: pass %s fail %s\n' "$(basename "$0")" "$PASSES" "$FAILS"; [ "$FAILS" -eq 0 ]; }
