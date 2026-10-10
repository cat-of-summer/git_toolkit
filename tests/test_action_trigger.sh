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
    INPUT_COMMITS= INPUT_RUN_CI= INPUT_RUN_RELEASE= INPUT_RUN_CD= \
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

# warm_cache: ci прогревает кеш на ветке по умолчанию, когда сам там не запускается.
while IFS='|' read -r name trigger ref_type ref_name build expect; do
  out="$tmp/out"; : > "$out"
  log="$(env -i PATH="$PATH" HOME="${HOME:-/tmp}" \
    GITHUB_OUTPUT="$out" \
    ACTION_TRIGGER="$trigger" EVENT=push REF_TYPE="$ref_type" REF_NAME="$ref_name" REF_NAME_NORM=x \
    DEFAULT_BRANCH=main BUILD_COMMAND="$build" CI_COMMAND= \
    DEPLOY_METHOD=command DEPLOY_MIRROR=false DEPLOY_LAST_COMMITS=false \
    INPUT_COMMITS= RUNS_ON= PUBLISH_METHOD= \
    bash "$SCRIPT" 2>&1)" || { fail "$name" "шаг упал" "$log"; continue; }
  check_eq "$name" "$expect" "$(grep -m1 '^warm_cache=' "$out" | cut -d= -f2)"
done <<'CASES'
warm: tag-триггер, push в main|tag|branch|main|make|true
warm: push в не-main ветку|tag|branch|feature|make|false
warm: ci и так идёт на main|push|branch|main|make|false
warm: нет команд сборки и тестов|tag|branch|main||false
warm: тег|tag|tag|v1.0.0|make|false
CASES

# scope деплоя: что заливается и откуда берётся список файлов. expect: scope,delta,commits либо !error:<подстрока>.
while IFS='|' read -r name trigger event ref_type method mirror last commits expect; do
  out="$tmp/out"; : > "$out"
  log="$(env -i PATH="$PATH" HOME="${HOME:-/tmp}" \
    GITHUB_OUTPUT="$out" \
    ACTION_TRIGGER="$trigger" EVENT="$event" REF_TYPE="$ref_type" REF_NAME=main REF_NAME_NORM=x \
    DEFAULT_BRANCH=main BUILD_COMMAND= CI_COMMAND= \
    DEPLOY_HOST=h DEPLOY_USER=u DEPLOY_KEY=k DEPLOY_PATH=p \
    DEPLOY_METHOD="$method" DEPLOY_MIRROR="$mirror" DEPLOY_LAST_COMMITS="$last" \
    INPUT_COMMITS="$commits" RUNS_ON= PUBLISH_METHOD= \
    bash "$SCRIPT" 2>&1)"
  code=$?
  if [ "${expect#!error:}" != "$expect" ]; then
    want="${expect#!error:}"
    if [ "$code" -ne 0 ] && printf '%s' "$log" | grep -qF "$want"; then pass "$name"; else fail "$name" "ожидалась ошибка «$want»" "$log"; fi
    continue
  fi
  [ "$code" -eq 0 ] || { fail "$name" "шаг упал" "$log"; continue; }
  check_eq "$name" "$expect" "$(grep -m1 '^scope=' "$out" | cut -d= -f2),$(grep -m1 '^delta=' "$out" | cut -d= -f2),$(grep -m1 '^commits=' "$out" | cut -d= -f2)"
done <<'CASES'
scope: push ветки с LAST_COMMITS — дельта|push|push|branch|rsync|true|true||selective,true,
scope: push ветки без LAST_COMMITS — полный|push|push|branch|rsync|true|false||full,false,
scope: push тега с LAST_COMMITS — полный|push|push|tag|rsync|true|true||full,false,
scope: ручной с commits — покоммитный|push|workflow_dispatch|branch|ftp|true|true|abc,def|selective,false,abc,def
scope: ручной без commits — полный|push|workflow_dispatch|branch|ftp|true|true||full,false,
scope: деплой командой|push|push|branch|command|true|true||none,false,
scope: tag-триггер с LAST_COMMITS запрещён|tag|push|tag|rsync|true|true||!error:has no effect with ACTION_TRIGGER=tag
scope: tag-триггер с LAST_COMMITS, ручной запуск|tag|workflow_dispatch|branch|rsync|true|true||!error:has no effect with ACTION_TRIGGER=tag
scope: tag-триггер без LAST_COMMITS|tag|push|tag|rsync|true|false||full,false,
scope: DEPLOY_MIRROR=full с дельтой запрещён|push|push|branch|rsync|full|true||!error:incompatible with selective
scope: git с дельтой запрещён|push|push|branch|git|true|true||!error:not supported in selective
CASES

suite_result "action-trigger"
