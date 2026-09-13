#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/assert.sh
. "$HERE/lib/assert.sh"

SNIPPET="$ROOT/.github/snippets/resolve-ref.sh"
CASES="$HERE/cases/resolve-ref.tsv"

run_case() {
  local event="$1" ref_type="$2" ref_name="$3" mp="$4" extra="$5" outfile="$6" envfile="$7"
  env -i \
    PATH="$PATH" HOME="${HOME:-/tmp}" \
    GITHUB_EVENT_NAME="$event" \
    GITHUB_REF_TYPE="$ref_type" \
    GITHUB_REF_NAME="$ref_name" \
    GITHUB_SHA=1111111111111111111111111111111111111111 \
    MULTIPLE_PACKAGES="$mp" \
    GITHUB_OUTPUT="$outfile" \
    GITHUB_ENV="$envfile" \
    bash -c '
      set -euo pipefail
      [ -n "${1:-}" ] && eval "export $1"
      . "$2"
    ' _ "$extra" "$SNIPPET" 2>&1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

while IFS='|' read -r name event ref_type ref_name mp extra expect; do
  name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"
  [ -z "$name" ] && continue
  case "$name" in \#*) continue ;; esac

  for v in event ref_type ref_name mp extra expect; do
    printf -v "$v" '%s' "$(printf '%s' "${!v}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  done

  out="$tmp/out"; envf="$tmp/env"
  : > "$out"; : > "$envf"

  log="$(run_case "$event" "$ref_type" "$ref_name" "$mp" "$extra" "$out" "$envf")"
  code=$?

  if [ "${expect#!error:}" != "$expect" ]; then
    want="${expect#!error:}"
    if [ "$code" -eq 0 ]; then
      fail "$name" "шаг обязан был упасть с «$want», но завершился успешно" "$log"
    elif ! printf '%s' "$log" | grep -qF "$want"; then
      fail "$name" "ожидалась ошибка со словами «$want»" "получено: $log"
    else
      pass "$name"
    fi
    continue
  fi

  if [ "$code" -ne 0 ]; then
    fail "$name" "шаг упал, хотя не должен был" "$log"
    continue
  fi

  bad=()
  IFS=';' read -ra wants <<< "$expect"
  for kv in "${wants[@]}"; do
    [ -z "$kv" ] && continue
    key="${kv%%=*}"; want="${kv#*=}"
    got="$(grep -m1 "^${key}=" "$out" | cut -d= -f2-)"
    [ "$got" = "$want" ] || bad+=("$key: ожидалось «$want», получено «$got»")
  done

  for key in REF_TYPE REF_NAME REF_NAME_NORM REF_COMMIT; do
    grep -q "^${key}=" "$envf" || bad+=("$key не записан в GITHUB_ENV")
  done

  if [ ${#bad[@]} -eq 0 ]; then pass "$name"; else fail "$name" "${bad[@]}"; fi
done < "$CASES"

suite_result "resolve-ref"
