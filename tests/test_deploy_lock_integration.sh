#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

have_docker() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }
win_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

if [ -f /.dockerenv ] || ! have_docker; then
  echo "  пропущено: стенду sshd + vsftpd нужен Docker на хосте"
  exit 0
fi

REPO_DIR="$(win_path "$ROOT")"
export REPO_DIR
COMPOSE="$(win_path "$HERE/deploy-lock/compose.yaml")"
dc() { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' docker compose -f "$COMPOSE" "$@"; }

trap '[ -n "${KEEP_STACK:-}" ] || dc down -v --remove-orphans >/dev/null 2>&1' EXIT

if ! dc up -d --build --force-recreate --renew-anon-volumes --quiet-pull >/tmp/deploy-lock-up.log 2>&1; then
  echo "  FAIL стенд не поднялся:"
  sed 's/^/       /' /tmp/deploy-lock-up.log | tail -30
  exit 1
fi

rc=0
dc exec -T runner bash /repo/tests/deploy-lock/scenarios.sh < /dev/null || rc=$?
exit "$rc"
