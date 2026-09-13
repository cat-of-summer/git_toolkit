#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/assert.sh
. "$HERE/lib/assert.sh"
# shellcheck source=lib/extract_step.sh
. "$HERE/lib/extract_step.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

SCRIPT="$tmp/decide.sh"
extract_step "$ROOT/.github/workflows/ci-cd.yml" decide > "$SCRIPT"

if [ ! -s "$SCRIPT" ]; then
  fail "шаг decide извлечён из ci-cd.yml" "по id: decide ничего не нашлось"
  suite_result "action-trigger"
  exit 1
fi

while IFS='|' read -r name trigger event ref_type expect; do
  for v in name trigger event ref_type expect; do
    printf -v "$v" '%s' "$(printf '%s' "${!v}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  done
  [ -z "$name" ] && continue
  case "$name" in \#*) continue ;; esac

  out="$tmp/out"; : > "$out"
  log="$(env -i PATH="$PATH" HOME="${HOME:-/tmp}" \
    GITHUB_OUTPUT="$out" \
    ACTION_TRIGGER="$trigger" \
    EVENT="$event" \
    REF_TYPE="$ref_type" \
    REF_NAME_NORM=x \
    BUILD_COMMAND='true' \
    CI_COMMAND='true' \
    DEPLOY_HOST=h DEPLOY_USER=u DEPLOY_KEY=k DEPLOY_PATH=p \
    DEPLOY_METHOD=command DEPLOY_MIRROR=false DEPLOY_LAST_COMMITS=false \
    INPUT_COMMITS= PUSH_COMMITS= INPUT_RUN_CI= INPUT_RUN_RELEASE= INPUT_RUN_CD= \
    RUNS_ON= PUBLISH_METHOD= \
    bash "$SCRIPT" 2>&1)"
  code=$?

  if [ "${expect#!error:}" != "$expect" ]; then
    want="${expect#!error:}"
    if [ "$code" -eq 0 ]; then
      fail "$name" "должно было упасть с «$want»" "$log"
    elif printf '%s' "$log" | grep -qF "$want"; then
      pass "$name"
    else
      fail "$name" "ожидалась ошибка «$want»" "$log"
    fi
    continue
  fi

  if [ "$code" -ne 0 ]; then
    fail "$name" "шаг упал, хотя не должен был" "$log"
    continue
  fi

  IFS=',' read -r want_ci want_rel want_cd <<< "$expect"
  got="$(grep -m1 '^run_ci=' "$out" | cut -d= -f2),$(grep -m1 '^run_release=' "$out" | cut -d= -f2),$(grep -m1 '^run_cd=' "$out" | cut -d= -f2)"
  check_eq "$name" "${want_ci},${want_rel},${want_cd}" "$got"
done < "$HERE/cases/action-trigger.tsv"

suite_result "action-trigger"
