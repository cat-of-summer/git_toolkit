#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
. "$HERE/lib/assert.sh"

out="$(bash "$HERE/sync.sh" --check 2>&1)"
code=$?

if [ "$code" -eq 0 ]; then
  while IFS= read -r line; do
    case "$line" in *"  ok   "*) pass "${line#*ok   }" ;; esac
  done <<< "$out"
else
  fail "встроенные копии сниппетов совпадают с .github/snippets" "$out"
fi

suite_result "sync"
