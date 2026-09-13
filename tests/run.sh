#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

IMAGE=git-toolkit-tests
ACTIONLINT_IMAGE=rhysd/actionlint:latest
SUITES="resolve_ref resolve_env action_trigger sync no_stale_refs"

usage() {
  cat <<'USAGE'
tests/run.sh [--docker|--local] [фильтр]

  --docker   прогон в контейнере (по умолчанию, если Docker доступен)
  --local    прогон здесь же, без контейнера; так же идёт в CI
  фильтр     запустить только наборы, чьё имя содержит подстроку

Наборы: resolve-ref, resolve-env, action-trigger, sync, no-stale-refs.
Линтеры actionlint и shellcheck запускаются без фильтра и требуют Docker
(shellcheck берётся с хоста, если он там установлен).
USAGE
}

MODE=""
FILTER=""
for arg in "$@"; do
  case "$arg" in
    --docker) MODE=docker ;;
    --local)  MODE=local ;;
    -h|--help) usage; exit 0 ;;
    *) FILTER="$arg" ;;
  esac
done

have_docker() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

dk() { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' docker "$@"; }

win_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

build_image() {
  [ -n "${IMAGE_READY:-}" ] && return 0
  dk build -q -t "$IMAGE" "$(win_path "$HERE")" >/dev/null || return 1
  IMAGE_READY=1
}

if [ -z "$MODE" ]; then
  if [ -f /.dockerenv ] || [ "${GITHUB_ACTIONS:-}" = "true" ]; then MODE=local
  elif have_docker; then MODE=docker
  else MODE=local
  fi
fi

status=0

if [ "$MODE" = "docker" ]; then
  if ! have_docker; then
    echo "::error::Docker недоступен. Запустите tests/run.sh --local." >&2
    exit 1
  fi
  echo "== образ для тестов =="
  build_image || exit 1
  echo "  ok   $IMAGE"
  echo
  dk run --rm -v "$(win_path "$ROOT"):/repo" -w /repo "$IMAGE" \
    tests/run.sh --local ${FILTER:+"$FILTER"} || status=1
else
  for suite in $SUITES; do
    file="$HERE/test_${suite}.sh"
    [ -f "$file" ] || continue
    if [ -n "$FILTER" ] && [ "${suite#*"${FILTER//-/_}"}" = "$suite" ]; then continue; fi
    echo "== ${suite//_/-} =="
    bash "$file" || status=1
    echo
  done
fi

run_linters=0
if [ -z "$FILTER" ] && [ ! -f /.dockerenv ]; then run_linters=1; fi

if [ "$run_linters" = 1 ]; then
  echo "== actionlint =="
  if ! have_docker; then
    echo "  пропущен: нет Docker, а нативного actionlint на хосте не бывает"
  elif dk run --rm -v "$(win_path "$ROOT"):/repo" -w /repo "$ACTIONLINT_IMAGE" -color; then
    echo "  ok   замечаний нет"
  else
    echo "  замечания выше; блокирует только синтаксис, shellcheck-инфо — нет"
  fi
  echo

  echo "== shellcheck =="
  sc_files=("$ROOT"/tests/*.sh "$ROOT"/tests/lib/*.sh)
  if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck --shell=bash --severity=warning "${sc_files[@]}"; then
      echo "  ok   скрипты тестов чисты"
    else
      status=1
    fi
  elif have_docker && build_image; then
    if dk run --rm -v "$(win_path "$ROOT"):/repo" -w /repo "$IMAGE" -c \
      'shellcheck --shell=bash --severity=warning tests/*.sh tests/lib/*.sh'; then
      echo "  ok   скрипты тестов чисты"
    else
      status=1
    fi
  else
    echo "  пропущен: нет ни shellcheck на хосте, ни Docker"
  fi
  echo
fi

if [ "$status" -eq 0 ]; then echo "ВСЁ ЗЕЛЁНОЕ"; else echo "ЕСТЬ ПАДЕНИЯ"; fi
exit "$status"
