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

SCRIPT="$tmp/deploy-files.sh"
extract_step "$ROOT/.github/workflows/ci-cd.yml" deploy-files > "$SCRIPT"

if [ ! -s "$SCRIPT" ]; then
  fail "шаг deploy-files извлечён из ci-cd.yml" "по id: deploy-files ничего не нашлось"
  suite_result "deploy-files"
  exit 1
fi

# --- репозиторий: история с удалением, веткой и merge с разрешённым конфликтом -----------------------
R="$tmp/repo"
mkdir -p "$R"
g() { git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
put() { mkdir -p "$(dirname "$R/$1")"; printf '%s\n' "$2" > "$R/$1"; }

g init -q -b main
put a.txt a1; put b.txt b1; put conf.txt base; put web/x.php x1; put .gitignore '*.log'
g add -A; g commit -q -m c1; C1="$(g rev-parse HEAD)"

put a.txt a2; put c.txt c1; put web/x.php x2; g rm -q b.txt
g add -A; g commit -q -m c2; C2="$(g rev-parse HEAD)"

g checkout -q -b feat "$C2"
put conf.txt feat; put f.txt f1
g add -A; g commit -q -m f1

g checkout -q main
put conf.txt main
g add -A; g commit -q -m c3; C3="$(g rev-parse HEAD)"

g merge -q feat -m merge >/dev/null 2>&1
put conf.txt merged; put evil.txt only-in-merge
g add -A; g commit -q -m merge; M="$(g rev-parse HEAD)"

# --- прогон шага ---------------------------------------------------------------------------------
run() {
  local delta="$1" base="$2" target="$3" commits="$4" mirror="$5" local_dir="$6" rt
  rt="$(mktemp -d "$tmp/rt.XXXX")"
  LOG="$(cd "$R" && env -i PATH="$PATH" HOME="${HOME:-/tmp}" \
    RUNNER_TEMP="$rt" GITHUB_REPOSITORY=o/app \
    LK_DELTA="$delta" DEPLOY_BASE="$base" TARGET_COMMIT="$target" COMMITS="$commits" \
    DEPLOY_MIRROR="$mirror" DEPLOY_LOCAL_DIR="$local_dir" \
    bash "$SCRIPT" 2>&1)"
  CODE=$?
  UP="$(tr '\n' ' ' < "$rt/files_upload.txt" 2>/dev/null | sed 's/ $//')"
  DEL="$(tr '\n' ' ' < "$rt/files_delete.txt" 2>/dev/null | sed 's/ $//')"
}

check() {
  local label="$1" want_up="$2" want_del="$3"
  if [ "$CODE" -ne 0 ]; then fail "$label" "шаг упал" "$LOG"; return; fi
  check_eq "$label: заливается" "$want_up" "$UP"
  check_eq "$label: удаляется" "$want_del" "$DEL"
}

warned() { printf '%s' "$LOG" | grep -q '::warning::'; }

run true "$C1" "$C2" "" true ./
check "дельта: изменение, добавление, удаление" "a.txt c.txt web/x.php" "b.txt"

run true "$C1" "$C2" "" false ./
check "дельта при DEPLOY_MIRROR=false не удаляет" "a.txt c.txt web/x.php" ""

run true "$C3" "$M" "" true ./
check "дельта через merge: разрешение конфликта и правка в самом merge" "conf.txt evil.txt f.txt" ""

run true "$C1" "$C2" "" true web/
check "дельта с DEPLOY_LOCAL_DIR" "x.php" ""

run true "$M" "$M" "" true ./
check "дельта без изменений" "" ""
if warned; then fail "дельта без изменений: без warning" "$LOG"; else pass "дельта без изменений: без warning"; fi

run true "" "$C2" "" true ./
check "дельта без записи о прошлом деплое — все отслеживаемые файлы" ".gitignore a.txt c.txt conf.txt web/x.php" "b.txt"

run true "0123456789abcdef0123456789abcdef01234567" "$C2" "" true ./
check "дельта от пропавшего коммита — все отслеживаемые файлы" ".gitignore a.txt c.txt conf.txt web/x.php" "b.txt"
if warned; then pass "пропавший коммит базы — warning"; else fail "пропавший коммит базы — warning" "$LOG"; fi

run true "" "$C2" "" false ./
check "DEPLOY_MIRROR=false не везёт .gitignore" "a.txt c.txt conf.txt web/x.php" ""

run false "" "$M" "$M" true ./
check "покоммитный: merge-коммит отдаёт всё влитое" "conf.txt evil.txt f.txt" ""

run false "" "$C1" "$C1" true ./
check "покоммитный: первый коммит репозитория" ".gitignore a.txt b.txt conf.txt web/x.php" ""

run false "" "$C2" "$C1,$C2" true ./
check "покоммитный: несколько коммитов, удалённое в них" ".gitignore a.txt c.txt conf.txt web/x.php" "b.txt"

suite_result "deploy-files"
