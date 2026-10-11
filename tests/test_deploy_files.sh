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

# Ветка от C2, где коммит возвращает a.txt к a1: дельта C1..R его не видит, а упавший деплой C2 мог
# успеть залить a2.
g checkout -q -b revert "$C2"
put a.txt a1
g add -A; g commit -q -m revert; R_="$(g rev-parse HEAD)"
g checkout -q main

ZERO=0000000000000000000000000000000000000000
GONE=0123456789abcdef0123456789abcdef01234567

# --- прогон шага ---------------------------------------------------------------------------------
# run delta base target commits mirror local_dir [push_before extra fallback [repo]]
run() {
  local delta="$1" base="$2" target="$3" commits="$4" mirror="$5" local_dir="$6"
  local before="${7:-}" extra="${8:-}" fallback="${9:-push}" repo="${10:-$R}" rt
  rt="$(mktemp -d "$tmp/rt.XXXX")"
  LOG="$(cd "$repo" && env -i PATH="$PATH" HOME="${HOME:-/tmp}" \
    RUNNER_TEMP="$rt" GITHUB_REPOSITORY=o/app \
    LK_DELTA="$delta" DEPLOY_BASE="$base" TARGET_COMMIT="$target" COMMITS="$commits" \
    DEPLOY_MIRROR="$mirror" DEPLOY_LOCAL_DIR="$local_dir" \
    PUSH_BEFORE="$before" DEPLOY_EXTRA="$extra" DEPLOY_FALLBACK="$fallback" \
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
check_warned() {
  if warned; then pass "$1: warning"; else fail "$1: warning" "$LOG"; fi
}

TREE_C2=".gitignore a.txt c.txt conf.txt web/x.php"

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

run true "" "$M" "" true ./ "$C3"
check "без записи о прошлом деплое — диапазон пуша" "conf.txt evil.txt f.txt" ""

run true "" "$C2" "" true ./ "$C1"
check "диапазон пуша удаляет удалённое в нём" "a.txt c.txt web/x.php" "b.txt"

run true "" "$C2" "" true ./ "$ZERO"
check "без записи и без диапазона (новая ветка) — всё дерево без удалений" "$TREE_C2" ""
check_warned "всё дерево без удалений"

run true "" "$C2" "" true ./ ""
check "без записи и без события push — всё дерево без удалений" "$TREE_C2" ""

run true "$GONE" "$C2" "" true ./ "$C1"
check "пропавший коммит базы — диапазон пуша" "a.txt c.txt web/x.php" "b.txt"
check_warned "пропавший коммит базы"

run true "$GONE" "$C2" "" true ./ "$ZERO"
check "пропавший коммит базы без диапазона — всё дерево без удалений" "$TREE_C2" ""

run true "" "$C2" "" false ./ "$ZERO"
check "DEPLOY_MIRROR=false не везёт .gitignore" "a.txt c.txt conf.txt web/x.php" ""

run true "$C1" "$R_" "" true ./ "" "$C2" tree
check "упавший деплой: его файлы перезаливаются в состоянии цели" "a.txt c.txt web/x.php" "b.txt"

run true "$C1" "$R_" "" true ./ "" "" push
check "без упавшего деплоя вернувшийся файл не трогается" "c.txt web/x.php" "b.txt"

run true "$C1" "$R_" "" true ./ "" "$GONE" tree
check "пропавший коммит упавшего деплоя — всё дерево без удалений" "$TREE_C2" ""
check_warned "пропавший коммит упавшего деплоя"

run true "" "$R_" "" true ./ "$C2" "$C2" tree
check "упавший деплой без базы: диапазон пуша не годится — всё дерево" "$TREE_C2" ""

run false "" "$M" "$M" true ./
check "покоммитный: merge-коммит отдаёт всё влитое" "conf.txt evil.txt f.txt" ""

run false "" "$C1" "$C1" true ./
check "покоммитный: первый коммит репозитория" ".gitignore a.txt b.txt conf.txt web/x.php" ""

run false "" "$C2" "$C1,$C2" true ./
check "покоммитный: несколько коммитов, удалённое в них" ".gitignore a.txt c.txt conf.txt web/x.php" "b.txt"

# --- DoorStudio, 2026-10-11: первый delta после записи старого формата ------------------------------
# Сервер хранил запись прошлого push-деплоя без поля deployed (scope=selective, status=ok). В истории —
# удалённый knight.ico и переименованные миграции. Мердж PR из 5 коммитов правит один CSS: заливается
# только он, и ничего не удаляется. Раньше шаг уходил во «все пути истории»: 1186 файлов, 5 удалений.
D="$tmp/doorstudio"
mkdir -p "$D"
gd() { git -C "$D" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
pd() { mkdir -p "$(dirname "$D/$1")"; printf '%s\n' "$2" > "$D/$1"; }
MIG=wp-content/themes/doorstudio/migrations
CSS=wp-content/themes/doorstudio/css/door-configurator.css

gd init -q -b dev
pd index.php i; pd knight.ico k; pd .htaccess h1; pd "$CSS" css0
pd "$MIG/2026_10_07_02_model_photo.php" m; pd "$MIG/2026_10_07_03_color_choice_flag.php" f
gd add -A; gd commit -q -m first
gd rm -q "$MIG/2026_10_07_02_model_photo.php" "$MIG/2026_10_07_03_color_choice_flag.php"
pd "$MIG/2026_10_07_01_palette.php" p; pd "$MIG/2026_10_07_02_color_choice_flag.php" f
gd add -A; gd commit -q -m renumber
gd rm -q knight.ico; pd .htaccess h2
gd add -A; gd commit -q -m sync; DS_BEFORE="$(gd rev-parse HEAD)"
gd checkout -q -b pr
for n in 1 2 3 4 5; do pd "$CSS" "css$n"; gd add -A; gd commit -q -m "css $n"; done
gd checkout -q dev
gd merge -q --no-ff pr -m merge; DS_MERGE="$(gd rev-parse HEAD)"

LOCK="$tmp/deploy-lock.sh"
cp "$ROOT/.github/snippets/deploy-lock.sh" "$LOCK"

# База от блокировки: запись run #5 старого формата (legacy) или её нет (none), текущий запуск #6 — delta.
# shellcheck disable=SC2034  # LK_* читаются функциями подключённого сниппета
ds_lock() {
  (
    # shellcheck source=../.github/snippets/deploy-lock.sh
    . "$LOCK"
    LK_TRANSPORT=local LK_BASE="$tmp/lk.$1"
    LK_REPO=cat-of-summer/DoorStudio---wordpress LK_WORKFLOW=w LK_ENVIRONMENT=dev LK_SOURCE=branch:dev
    lkt_ensure_base
    if [ "$1" = legacy ]; then
      printf 'run_number=5\nrun_id=r5\ntoken=OLD\nstatus=ok\nscope=selective\ncommit=%s\n' "$DS_BEFORE" \
        | lkt_write "state/$(lk_state_key)"
    fi
    LK_SCOPE=selective LK_DELTA=true LK_RUN_NUMBER=6 LK_RUN_ID=r6 LK_TOKEN=NEW LK_COMMIT="$DS_MERGE"
    lk_check_state 2>/dev/null || exit 9
    printf '%s|%s|%s' "$LK_DEPLOY_BASE" "$LK_DEPLOY_EXTRA" "$LK_DEPLOY_FALLBACK"
  )
}

IFS='|' read -r ds_base ds_extra ds_fb <<< "$(ds_lock legacy)"
check_eq "DoorStudio: база из записи старого формата" "$DS_BEFORE" "$ds_base"
run true "$ds_base" "$DS_MERGE" "" true ./ "$DS_BEFORE" "$ds_extra" "$ds_fb" "$D"
check "DoorStudio: мердж PR по записи старого формата" "$CSS" ""

IFS='|' read -r ds_base ds_extra ds_fb <<< "$(ds_lock none)"
run true "$ds_base" "$DS_MERGE" "" true ./ "$DS_BEFORE" "$ds_extra" "$ds_fb" "$D"
check "DoorStudio: мердж PR без записи (очищенный /tmp)" "$CSS" ""

run true "" "$DS_MERGE" "" true ./ "$ZERO" "" push "$D"
check "DoorStudio: без записи и без диапазона — дерево, knight.ico и миграции не удаляются" \
  ".htaccess index.php $CSS $MIG/2026_10_07_01_palette.php $MIG/2026_10_07_02_color_choice_flag.php" ""

suite_result "deploy-files"
