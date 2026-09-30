#!/usr/bin/env bash
# shellcheck disable=SC2034  # LK_* читаются функциями подключённого сниппета
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/assert.sh
. "$HERE/lib/assert.sh"

SNIPPET="$ROOT/.github/snippets/deploy-lock.sh"

T="$(mktemp -d)"
chmod 755 "$T"
cp "$SNIPPET" "$T/deploy-lock.sh"
chmod 644 "$T/deploy-lock.sh"
S="$T/deploy-lock.sh"
cleanup() {
  jobs -p | xargs -r kill 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT

# shellcheck source=../.github/snippets/deploy-lock.sh
. "$S"
LK_TRANSPORT=local
LK_POLL=0.1
LK_STALE=100
LK_WAIT=100
LK_BEAT=0.2
LK_LOG_EVERY=100000

tok()      { lk_field token "$(cat "$1/deploy.lock/owner" 2>/dev/null)" || true; }
leftover() { find "$1" -maxdepth 1 -name 'deploy.lock.*' 2>/dev/null | wc -l | tr -d ' '; }
has()      { grep -qF -- "$2" "$1"; }

wait_for() {
  local pid="$1" n=$(( $2 * 10 ))
  while kill -0 "$pid" 2>/dev/null && [ "$n" -gt 0 ]; do sleep 0.1; n=$(( n - 1 )); done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124; fi
  wait "$pid"
}

use_vclock() {
  CLOCK="$1"
  echo 1000 > "$CLOCK"
  lk_now() { cat "$CLOCK"; }
  lk_sleep() {
    local s="${1%.*}"
    [ -z "$s" ] || [ "$s" = 0 ] && s=1
    echo $(( $(cat "$CLOCK") + s )) > "$CLOCK"
    if declare -F on_sleep >/dev/null; then on_sleep; fi
  }
}

hold() {
  local base="$1" token="$2"
  ( LK_BASE="$base" LK_TOKEN="$token" LK_REPO="org/$token" LK_RUN_URL="https://gh/runs/$token"
    lk_acquire ) 2>/dev/null
}

# --- 1. свободный замок --------------------------------------------------------------------------
b="$T/free"
( LK_BASE="$b" LK_TOKEN=A LK_REPO=org/app LK_ENVIRONMENT=main LK_SOURCE=branch:main LK_RUN_NUMBER=12
  lk_acquire ) 2>"$T/free.log"
check_eq "свободный замок берётся сразу" 0 "$?"
check_eq "в owner записан token" A "$(tok "$b")"
check_eq "в owner записан repo" org/app "$(lk_field repo "$(cat "$b/deploy.lock/owner")")"
check_eq "в owner записан source" branch:main "$(lk_field source "$(cat "$b/deploy.lock/owner")")"
check_eq "beat начинается с нуля" "A 0" "$(cat "$b/deploy.lock/beat.A")"
check_eq "база с правами 0777" 777 "$(stat -c %a "$b")"
check_eq "state с правами 0777" 777 "$(stat -c %a "$b/state")"
check_eq "замок с правами 0777" 777 "$(stat -c %a "$b/deploy.lock")"
if has "$T/free.log" "Deploy lock acquired"; then pass "в лог пишется захват"; else fail "в лог пишется захват" "$(cat "$T/free.log")"; fi

# --- 2. занятый замок: ждём, после release проходим ---------------------------------------------
b="$T/busy"
hold "$b" A
( LK_BASE="$b" LK_TOKEN=B; lk_acquire ) 2>"$T/busy.log" &
pid=$!
sleep 1
check_eq "пока A держит, B не заходит" A "$(tok "$b")"
if kill -0 "$pid" 2>/dev/null; then pass "B ждёт, а не падает"; else fail "B ждёт, а не падает" "$(cat "$T/busy.log")"; fi
( LK_BASE="$b" LK_TOKEN=A; lk_release ) 2>/dev/null
wait_for "$pid" 5
check_eq "после release A замок берёт B" "0 B" "$? $(tok "$b")"
if has "$T/busy.log" "org/A" && has "$T/busy.log" "https://gh/runs/A"; then
  pass "лог ожидания называет держателя (repo и run URL)"
else
  fail "лог ожидания называет держателя (repo и run URL)" "$(cat "$T/busy.log")"
fi

# --- 3. стресс: 8 параллельных захватчиков -------------------------------------------------------
stress() {
  local base="$1" n="$2" stale="$3" i
  echo 0 > "$T/cnt"; rm -f "$T/viol"; rmdir "$T/inside" 2>/dev/null
  for i in $(seq 1 "$n"); do
    ( LK_BASE="$base" LK_TOKEN="w$i" LK_POLL=0.05 LK_STALE="$stale"
      lk_acquire 2>/dev/null || { echo "acquire-fail w$i" >> "$T/viol"; exit 0; }
      mkdir "$T/inside" 2>/dev/null || echo "overlap w$i" >> "$T/viol"
      sleep 0.1
      echo $(( $(cat "$T/cnt") + 1 )) > "$T/cnt"
      rmdir "$T/inside"
      lk_release 2>/dev/null ) &
  done
  wait
}
stress "$T/stress" 8 100
check_eq "стресс: все 8 прошли критическую секцию" 8 "$(cat "$T/cnt")"
check_eq "стресс: ни одного наложения" "" "$(cat "$T/viol" 2>/dev/null)"
check_eq "стресс: замок после всех свободен" "" "$(tok "$T/stress")"
check_eq "стресс: не осталось .stale/.done" 0 "$(leftover "$T/stress")"

hold "$T/stress2" DEAD
stress "$T/stress2" 5 2
check_eq "стресс с брошенным замком на старте: все 5 прошли" 5 "$(cat "$T/cnt")"
check_eq "стресс с брошенным замком: ни одного наложения" "" "$(cat "$T/viol" 2>/dev/null)"
check_eq "стресс с брошенным замком: мусора нет" 0 "$(leftover "$T/stress2")"

# --- 4 и 8. живой держатель не снимается, ожидание кончается таймаутом ---------------------------
b="$T/alive"
hold "$b" A
( LK_BASE="$b" LK_TOKEN=B LK_WAIT=300 LK_STALE=30 LK_POLL=10 LK_LOG_EVERY=60
  use_vclock "$T/alive.clock"
  on_sleep() { printf 'A %s' "$(cat "$CLOCK")" > "$b/deploy.lock/beat.A"; }
  lk_acquire ) 2>"$T/alive.log"
check_eq "живой держатель: B падает по таймауту" 1 "$?"
check_eq "живой держатель: замок остался у A" A "$(tok "$b")"
if has "$T/alive.log" "gave up after 300s" && has "$T/alive.log" "org/A"; then
  pass "сообщение о таймауте называет держателя"
else
  fail "сообщение о таймауте называет держателя" "$(cat "$T/alive.log")"
fi
check_eq "при долгом ожидании лог повторяется раз в LOG_EVERY" 4 "$(grep -c 'Still waiting' "$T/alive.log")"
if has "$T/alive.log" "removed an abandoned lock"; then fail "живой замок не снимался" "$(cat "$T/alive.log")"; else pass "живой замок не снимался"; fi

# --- 5. брошенный замок снимается после LK_STALE --------------------------------------------------
b="$T/stale"
hold "$b" A
( LK_BASE="$b" LK_TOKEN=B LK_STALE=30 LK_POLL=10
  use_vclock "$T/stale.clock"
  lk_acquire ) 2>"$T/stale.log"
check_eq "брошенный замок: B заходит" "0 B" "$? $(tok "$b")"
waited=$(( $(cat "$T/stale.clock") - 1000 ))
if [ "$waited" -ge 30 ] && [ "$waited" -le 50 ]; then pass "брошенный замок снят не раньше LK_STALE ($waited с)"; else fail "брошенный замок снят не раньше LK_STALE" "ждали $waited с"; fi
if has "$T/stale.log" "removed an abandoned lock" && has "$T/stale.log" "org/A"; then
  pass "warning о снятии называет прежнего владельца"
else
  fail "warning о снятии называет прежнего владельца" "$(cat "$T/stale.log")"
fi
check_eq "после снятия нет мусора" 0 "$(leftover "$b")"

b="$T/noowner"
mkdir -p "$b/state" "$b/deploy.lock"
chmod 777 "$b" "$b/state"
( LK_BASE="$b" LK_TOKEN=B LK_STALE=30 LK_POLL=10
  use_vclock "$T/noowner.clock"
  lk_acquire ) 2>"$T/noowner.log"
check_eq "замок без owner (упали между mkdir и записью) снимается" "0 B" "$? $(tok "$b")"
if has "$T/noowner.log" "unknown owner"; then pass "лог честно пишет unknown owner"; else fail "лог честно пишет unknown owner" "$(cat "$T/noowner.log")"; fi

# --- 6. пульс держит замок, kill -9 пульса отпускает ---------------------------------------------
b="$T/hb"
hold "$b" A
( LK_BASE="$b" LK_TOKEN=A LK_BEAT=0.2; lk_heartbeat ) 2>/dev/null &
hb=$!
( LK_BASE="$b" LK_TOKEN=B LK_STALE=2 LK_POLL=0.1; lk_acquire ) 2>"$T/hb.log" &
pid=$!
sleep 3.5
check_eq "при живом пульсе замок у A дольше LK_STALE" A "$(tok "$b")"
beat_a="$(cat "$b/deploy.lock/beat.A")"
if [ "${beat_a#A }" -gt 3 ] 2>/dev/null; then pass "пульс растёт ($beat_a)"; else fail "пульс растёт" "$beat_a"; fi
kill -9 "$hb" 2>/dev/null
wait "$hb" 2>/dev/null
wait_for "$pid" 5
check_eq "после kill -9 пульса замок забирает B" "0 B" "$? $(tok "$b")"

# --- 7. LK_MAX_HOLD останавливает пульс ----------------------------------------------------------
b="$T/maxhold"
hold "$b" A
( LK_BASE="$b" LK_TOKEN=A LK_BEAT=0.2 LK_MAX_HOLD=1; lk_heartbeat ) 2>"$T/maxhold.log" &
hb=$!
wait_for "$hb" 4
check_eq "пульс сам останавливается через LK_MAX_HOLD" 0 "$?"
if has "$T/maxhold.log" "held for over 1s"; then pass "warning о превышении LK_MAX_HOLD"; else fail "warning о превышении LK_MAX_HOLD" "$(cat "$T/maxhold.log")"; fi
( LK_BASE="$b" LK_TOKEN=B LK_STALE=1 LK_POLL=0.1; lk_acquire ) 2>/dev/null &
pid=$!
wait_for "$pid" 5
check_eq "после остановки пульса замок забирается" "0 B" "$? $(tok "$b")"

# --- пульс замечает, что замок отобрали, и не пишет в чужой --------------------------------------
b="$T/lost"
hold "$b" A
( LK_BASE="$b" LK_TOKEN=A LK_BEAT=0.2; lk_heartbeat ) 2>"$T/lost.log" &
hb=$!
sleep 0.5
until rm -rf "$b/deploy.lock" 2>/dev/null; do :; done
hold "$b" C
wait_for "$hb" 3
check_eq "пульс выходит с ошибкой, когда замок отобран" 1 "$?"
if has "$T/lost.log" "taken over by org/C"; then pass "warning называет нового владельца"; else fail "warning называет нового владельца" "$(cat "$T/lost.log")"; fi
check_eq "beat нового владельца не перезаписан" "C 0" "$(cat "$b/deploy.lock/beat.C")"

b="$T/vanish"
hold "$b" A
( LK_BASE="$b" LK_TOKEN=A LK_BEAT=0.1; lk_heartbeat ) 2>"$T/vanish.log" &
hb=$!
sleep 0.3
until rm -rf "$b/deploy.lock" 2>/dev/null; do :; done
wait_for "$hb" 3
check_eq "пульс выходит после 3 неудачных попыток подряд" 1 "$?"
if has "$T/vanish.log" "failed 3 times"; then pass "warning о трёх неудачах"; else fail "warning о трёх неудачах" "$(cat "$T/vanish.log")"; fi

# --- 9. гонка ABA при снятии: свежий замок не удаляется ------------------------------------------
b="$T/aba"
hold "$b" A
( LK_BASE="$b" LK_TOKEN=B
  eval "orig_$(declare -f lkt_rename)"
  lkt_rename() {
    if [ ! -e "$T/aba.done" ]; then
      touch "$T/aba.done"
      rm -rf "$b/deploy.lock"
      ( LK_TOKEN=C LK_REPO=org/C; lk_acquire ) 2>/dev/null
    fi
    orig_lkt_rename "$@"
  }
  lk__steal A ) 2>/dev/null
check_eq "ABA: снятие отменено" 1 "$?"
check_eq "ABA: свежий замок C на месте" C "$(tok "$b")"
check_eq "ABA: переименованный каталог возвращён" 0 "$(leftover "$b")"

( LK_BASE="$b" LK_TOKEN=B; lk__steal WRONG ) 2>/dev/null
check_eq "снятие с чужим ожидаемым token ничего не делает" "1 C" "$? $(tok "$b")"

# --- 10. release -----------------------------------------------------------------------------------
b="$T/rel"
hold "$b" A
( LK_BASE="$b" LK_TOKEN=B; lk_release ) 2>"$T/rel.log"
check_eq "release чужого замка — код 0" 0 "$?"
check_eq "release чужого замка ничего не удаляет" A "$(tok "$b")"
if has "$T/rel.log" "not released"; then pass "release чужого пишет warning"; else fail "release чужого пишет warning" "$(cat "$T/rel.log")"; fi
( LK_BASE="$b" LK_TOKEN=A; lk_release; lk_release ) 2>"$T/rel2.log"
check_eq "двойной release безопасен" 0 "$?"
check_eq "после release замка нет" "" "$(tok "$b")"
check_eq "после release нет мусора" 0 "$(leftover "$b")"
( LK_BASE="$b" LK_TOKEN=""; lk_release ) 2>/dev/null
check_eq "release без token — no-op" 0 "$?"

# --- 11. устаревшие запуски: таблица кейсов --------------------------------------------------------
trim() { printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

write_record() {
  local base="$1" repo wf env src num
  IFS=';' read -r repo wf env src num <<< "$2"
  ( LK_BASE="$base" LK_REPO="$repo" LK_WORKFLOW="$wf" LK_ENVIRONMENT="$env" LK_SOURCE="$src"
    lkt_ensure_base
    printf 'run_number=%s\ncommit=abcdef0123\nrun_url=https://gh/runs/%s' "$num" "$num" | lkt_write "state/$(lk_state_key)" )
}

check_run() {
  local base="$1" repo wf env src num
  IFS=';' read -r repo wf env src num <<< "$2"
  ( LK_BASE="$base" LK_REPO="$repo" LK_WORKFLOW="$wf" LK_ENVIRONMENT="$env" LK_SOURCE="$src"
    LK_RUN_NUMBER="$num" LK_TOKEN=T
    lkt_ensure_base
    lk_check_state 2>"$T/sup.log" || exit 9
    printf '%s %s' "$LK_SUPERSEDED" "$(lk_field run_number "$(lkt_read "state/$(lk_state_key)" || true)" || true)" )
}

i=0
while IFS='|' read -r name prev cur expect; do
  name="$(trim "$name")"
  [ -z "$name" ] && continue
  case "$name" in \#*) continue ;; esac
  prev="$(trim "$prev")"; cur="$(trim "$cur")"; expect="$(trim "$expect")"
  i=$(( i + 1 ))
  b="$T/sup$i"
  [ "$prev" != "-" ] && write_record "$b" "$prev"
  got="$(check_run "$b" "$cur")"
  num="${cur##*;}"
  case "$expect" in
    skip)   want="true ${prev##*;}" ;;
    deploy) case "$num" in *[!0-9]*) want="false ${prev##*;}"; [ "$prev" = "-" ] && want="false " ;; *) want="false $num" ;; esac ;;
  esac
  check_eq "устаревание: $name" "$want" "$got"
done < "$HERE/cases/deploy-lock-superseded.tsv"

b="$T/chain"
cur="o/app;o/app/.github/workflows/ci.yml@refs/heads/main;main;branch:main"
got=""
for n in 5 7 6 7 8 3; do got="$got $(check_run "$b" "$cur;$n")"; done
check_eq "цепочка 5,7,6,7(re-run),8,3" " false 5 false 7 true 7 false 7 false 8 true 8" "$got"

write_record "$T/suplog" "o/app;w;main;branch:main;9"
check_run "$T/suplog" "o/app;w;main;branch:main;4" >/dev/null
if has "$T/sup.log" "newer run #9" && has "$T/sup.log" "https://gh/runs/9" && has "$T/sup.log" "abcdef0"; then
  pass "notice о пропуске называет более новый запуск, коммит и URL"
else
  fail "notice о пропуске называет более новый запуск, коммит и URL" "$(cat "$T/sup.log")"
fi

# --- незавершённый прошлый деплой: таблица кейсов --------------------------------------------------
st_env() { LK_REPO=o/app; LK_WORKFLOW=w; LK_ENVIRONMENT=main; LK_SOURCE=branch:main; }

i=0
while IFS='|' read -r name pstatus prun scope crun expect; do
  name="$(trim "$name")"
  [ -z "$name" ] && continue
  case "$name" in \#*) continue ;; esac
  pstatus="$(trim "$pstatus")"; prun="$(trim "$prun")"; scope="$(trim "$scope")"; crun="$(trim "$crun")"; expect="$(trim "$expect")"
  i=$(( i + 1 ))
  b="$T/st$i"
  got="$(
    LK_BASE="$b"; st_env; lkt_ensure_base
    if [ "$pstatus" != "-" ]; then
      { printf 'run_number=5\nrun_id=%s\ntoken=OLD\ncommit=0ld0ld0\nrun_url=https://gh/runs/5\n' "$prun"
        [ "$pstatus" = none ] || printf 'status=%s\n' "$pstatus"; } | lkt_write "state/$(lk_state_key)"
    fi
    LK_RUN_NUMBER=6 LK_RUN_ID="$crun" LK_SCOPE="$scope" LK_TOKEN=NEW
    rc=0; lk_check_state 2>"$T/st.log" || rc=$?
    rec="$(lkt_read "state/$(lk_state_key)")"
    printf '%s|%s|%s|%s' "$rc" "$(lk_field token "$rec")" "$(lk_field status "$rec")" \
      "$(grep -c '::warning::' "$T/st.log")"
  )"
  case "$expect" in
    deploy) want="0|NEW|running|0" ;;
    warn)   want="0|NEW|running|1" ;;
    block)  want="3|OLD|$pstatus|0" ;;
  esac
  check_eq "статус прошлого: $name" "$want" "$got"
  if [ "$expect" = block ]; then
    if has "$T/st.log" "Run a full deploy" && has "$T/st.log" "https://gh/runs/5"; then
      pass "статус прошлого: $name — ошибка объясняет, что делать"
    else
      fail "статус прошлого: $name — ошибка объясняет, что делать" "$(cat "$T/st.log")"
    fi
  fi
done < "$HERE/cases/deploy-lock-status.tsv"

b="$T/lifecycle"
life() {
  local run="$1" scope="$2" action="$3" rc=0
  ( LK_BASE="$b"; st_env; LK_RUN_NUMBER="$run" LK_RUN_ID="r$run" LK_SCOPE="$scope" LK_TOKEN="t$run"
    lkt_ensure_base
    lk_check_state 2>/dev/null || exit $?
    case "$action" in
      ok)    lk_mark_state ok ;;
      fail)  lk_mark_state failed running ;;
      crash) : ;;
    esac ) || rc=$?
  printf '%s:%s ' "$rc" "$(lk_field status "$(cat "$b"/state/* 2>/dev/null)")"
}
got="$(life 1 full ok)$(life 2 selective fail)$(life 3 selective ok)$(life 4 full ok)$(life 5 selective crash)$(life 6 selective ok)$(life 7 full ok)$(life 8 selective ok)"
check_eq "жизненный цикл: ok → сбой → selective блок → full чинит → умер → блок → full → selective" \
  "0:ok 0:failed 3:failed 0:ok 0:running 3:running 0:ok 0:ok " "$got"

( LK_BASE="$b"; st_env; LK_RUN_NUMBER=8 LK_TOKEN=t8; lk_mark_state failed running )
check_eq "Cleanup после успешного Release не портит ok" ok "$(lk_field status "$(cat "$b"/state/*)")"
( LK_BASE="$b"; st_env; LK_RUN_NUMBER=8 LK_TOKEN=other; lk_mark_state failed )
check_eq "чужой token не меняет запись" ok "$(lk_field status "$(cat "$b"/state/*)")"
( LK_BASE="$b"; st_env; LK_RUN_NUMBER=9 LK_RUN_ID=r9 LK_SCOPE=full LK_TOKEN=t9; lk_check_state; lk_mark_state failed running
  LK_RUN_NUMBER=7 LK_RUN_ID=r7 LK_TOKEN=t7; lk_check_state ) 2>/dev/null
check_eq "устаревший запуск не трогает пометку failed" "failed t9" \
  "$(lk_field status "$(cat "$b"/state/*)") $(lk_field token "$(cat "$b"/state/*)")"

# --- источник деплоя из resolve-ref ----------------------------------------------------------------
while IFS='|' read -r name rtype rname rnorm rbranch expect; do
  name="$(trim "$name")"
  [ -z "$name" ] && continue
  case "$name" in \#*) continue ;; esac
  got="$(REF_TYPE="$(trim "$rtype")" REF_NAME="$(trim "$rname")" REF_NAME_NORM="$(trim "$rnorm")" \
         REF_BRANCH="$(trim "$rbranch")" lk_source_from_ref)"
  check_eq "источник: $name" "$(trim "$expect")" "$got"
done < "$HERE/cases/deploy-lock-source.tsv"

# --- 12. спецсимволы в полях owner -----------------------------------------------------------------
b="$T/chars"
weird_repo='org/app "q" $HOME `x` = y'
weird_env='prod eu=1'
weird_url='https://gh/runs/1?a=b&c=d'
( LK_BASE="$b" LK_TOKEN=A LK_REPO="$weird_repo" LK_ENVIRONMENT="$weird_env" LK_RUN_URL="$weird_url"
  LK_COMMIT=$'abc\ndef'
  lk_acquire ) 2>/dev/null
o="$(cat "$b/deploy.lock/owner")"
check_eq "спецсимволы: repo читается как есть" "$weird_repo" "$(lk_field repo "$o")"
check_eq "спецсимволы: environment читается как есть" "$weird_env" "$(lk_field environment "$o")"
check_eq "спецсимволы: URL с '=' читается как есть" "$weird_url" "$(lk_field run_url "$o")"
check_eq "перевод строки в значении не ломает формат" "abc def" "$(lk_field commit "$o")"
check_eq "перевод строки не создаёт лишних полей" "" "$(lk_field def "$o" || true)"

# --- 13. база удалена во время ожидания -----------------------------------------------------------
b="$T/gone"
hold "$b" A
( LK_BASE="$b" LK_TOKEN=B LK_POLL=10
  use_vclock "$T/gone.clock"
  on_sleep() { [ -e "$T/gone.done" ] || { touch "$T/gone.done"; rm -rf "$b"; }; }
  lk_acquire ) 2>/dev/null
check_eq "база пропала посреди ожидания — пересоздана, замок взят" "0 B" "$? $(tok "$b")"
check_eq "пересозданная база снова 0777" 777 "$(stat -c %a "$b")"

( LK_BASE="$T/file-not-dir/x" LK_TOKEN=B; : > "$T/file-not-dir"; lk_acquire ) 2>"$T/nobase.log"
check_eq "база не создаётся — код 2" 2 "$?"
if has "$T/nobase.log" "cannot create"; then pass "ошибка о базе понятная"; else fail "ошибка о базе понятная" "$(cat "$T/nobase.log")"; fi

( LK_BASE="$T/tr" LK_TRANSPORT=bogus; lk_acquire ) 2>"$T/tr.log"
check_eq "неизвестный транспорт — код 2" 2 "$?"

# --- очередь: длинная, с зависшим, упавшим и отвалившимся участником ---------------------------
Q="$T/q"
q_reset() { rm -rf "$Q"; mkdir -p "$Q"; : > "$Q/order"; : > "$Q/done"; }

qworker() {
  local base="$1" id="$2" mode="$3" hold="$4"
  ( LK_BASE="$base" LK_TOKEN="$id" LK_REPO="org/$id" LK_POLL=0.05 LK_STALE=2 LK_BEAT=0.2 LK_WAIT=60
    [ "$mode" = hang ] && LK_MAX_HOLD=1
    lk_acquire 2>>"$Q/$id.log" || { echo "acquire-fail $id" >> "$Q/viol"; exit 0; }
    lk_heartbeat 2>>"$Q/$id.log" &
    hbp=$!
    echo "$id $(date +%s)" >> "$Q/order"
    case "$mode" in
      crash) kill -9 "$hbp"; wait "$hbp" 2>/dev/null; exit 0 ;;
      hang)  sleep "$hold"; kill "$hbp" 2>/dev/null; lk_release 2>>"$Q/$id.log"; exit 0 ;;
    esac
    mkdir "$Q/inside" 2>/dev/null || echo "overlap $id" >> "$Q/viol"
    sleep "$hold"
    rmdir "$Q/inside"
    echo "$id $(date +%s)" >> "$Q/done"
    kill "$hbp" 2>/dev/null
    lk_release 2>>"$Q/$id.log" ) &
}

q_steals() { cat "$Q"/*.log 2>/dev/null | grep -c "removed an abandoned lock"; }
q_check() {
  local label="$1" base="$2" want_done="$3"
  check_eq "$label: все прошли критическую секцию" "$want_done" "$(wc -l < "$Q/done" | tr -d ' ')"
  check_eq "$label: ни одного наложения и отказа" "" "$(cat "$Q/viol" 2>/dev/null)"
  check_eq "$label: замок в конце свободен" "" "$(tok "$base")"
  check_eq "$label: не осталось .stale/.done" 0 "$(leftover "$base")"
}

q_reset
b="$T/q-long"
started="$(date +%s)"
for i in $(seq -w 1 20); do qworker "$b" "n$i" ok 0.05; done
wait
q_check "очередь из 20" "$b" 20
check_eq "очередь из 20: каждый зашёл ровно один раз" 20 "$(sort -u "$Q/order" | wc -l | tr -d ' ')"
check_eq "очередь из 20: ни одного ложного снятия живого держателя" 0 "$(q_steals)"
took=$(( $(date +%s) - started ))
if [ "$took" -le 20 ]; then pass "очередь из 20 разошлась за $took с"; else fail "очередь из 20 разошлась слишком долго" "$took с"; fi

q_reset
b="$T/q-slow"
for i in 1 2 3; do qworker "$b" "s$i" ok 3; done
wait
q_check "держатели дольше LK_STALE" "$b" 3
check_eq "держатели дольше LK_STALE: живой пульс не даёт снять замок" 0 "$(q_steals)"

q_reset
b="$T/q-hang"
started="$(date +%s)"
qworker "$b" hang hang 6
until [ "$(tok "$b")" = hang ]; do sleep 0.05; done
qworker "$b" h1 ok 5
for i in 2 3 4; do qworker "$b" "h$i" ok 0.2; done
wait
q_check "зависший в очереди" "$b" 4
if grep -q "held for over 1s" "$Q/hang.log"; then pass "зависший: его пульс остановлен по LK_MAX_HOLD"; else fail "зависший: его пульс остановлен по LK_MAX_HOLD" "$(cat "$Q/hang.log")"; fi
if cat "$Q"/h*.log | grep "removed an abandoned lock" | grep -q "org/hang"; then
  pass "зависший: очередь сняла его замок и пошла дальше"
else
  fail "зависший: очередь сняла его замок и пошла дальше" "$(cat "$Q"/*.log)"
fi
if grep -q "not released" "$Q/hang.log" && ! grep -q "Deploy lock released" "$Q/hang.log"; then pass "зависший, очнувшись, не удалил чужой замок"; else fail "зависший, очнувшись, не удалил чужой замок" "$(cat "$Q/hang.log")"; fi
next=$(( $(grep -v "^hang " "$Q/order" | cut -d" " -f2 | sort -n | head -1) - started ))
if [ "$next" -lt 6 ]; then pass "зависший: очередь не ждала его 6 с (следующий взял замок через $next с)"; else fail "зависший: очередь ждала его до конца" "$next с"; fi

q_reset
b="$T/q-crash"
qworker "$b" crash crash 0
until [ "$(tok "$b")" = crash ]; do sleep 0.05; done
for i in 1 2 3 4 5; do qworker "$b" "c$i" ok 0.1; done
wait
q_check "упавший с замком в очереди" "$b" 5
check_eq "упавший: замок снят ровно один раз" 1 "$(q_steals)"
if cat "$Q"/c*.log | grep "removed an abandoned lock" | grep -q "org/crash"; then pass "упавший: warning называет упавшего"; else fail "упавший: warning называет упавшего" "$(cat "$Q"/*.log)"; fi

q_reset
b="$T/q-waiter"
qworker "$b" w1 ok 1.5; sleep 0.2
qworker "$b" victim ok 0.1
victim=$!
for i in 2 3 4; do qworker "$b" "w$i" ok 0.1; done
sleep 0.5
kill -9 "$victim" 2>/dev/null
wait "$victim" 2>/dev/null
wait
q_check "ожидающий убит в очереди" "$b" 4
check_eq "ожидающий убит: снятий не понадобилось" 0 "$(q_steals)"

q_reset
b="$T/q-mixed"
qworker "$b" crash crash 0; sleep 0.1
qworker "$b" hang hang 4; sleep 0.1
for i in $(seq -w 1 8); do qworker "$b" "m$i" ok 0.1; done
wait
q_check "смешанная очередь: упавший + зависший + 8 рабочих" "$b" 8

# --- общий каталог с FTP (DEPLOY_LOCK_DIR): SSH берёт два замка, FTP — один ------------------------
b="$T/dual-host"; sb="$T/dual-shared"
( LK_BASE="$b" LK_SHARED_BASE="$sb" LK_TOKEN=S1 LK_REPO=org/ssh; lk_acquire_all ) 2>/dev/null
check_eq "два замка: оба взяты одним token" "0 S1 S1" "$? $(tok "$b") $(tok "$sb")"
( LK_BASE="$b" LK_SHARED_BASE="$sb" LK_TOKEN=S1; lk_release_all ) 2>/dev/null
check_eq "два замка: оба отпущены" "|" "$(tok "$b")|$(tok "$sb")"

hold "$sb" F1
( LK_BASE="$b" LK_SHARED_BASE="$sb" LK_TOKEN=S2 LK_WAIT=2 LK_POLL=0.2; lk_acquire_all ) 2>"$T/dual.log"
check_eq "общий замок у FTP: SSH ждёт и по таймауту отпускает свой замок хоста" "1 |F1" "$? $(tok "$b")|$(tok "$sb")"
if has "$T/dual.log" "org/F1"; then pass "SSH в логе видит FTP-держателя общего замка"; else fail "SSH в логе видит FTP-держателя общего замка" "$(cat "$T/dual.log")"; fi
( LK_BASE="$sb" LK_TOKEN=F1; lk_release ) 2>/dev/null

( LK_BASE="$b" LK_SHARED_BASE="$sb" LK_TOKEN=S3; lk_acquire_all ) 2>/dev/null
( LK_BASE="$b" LK_SHARED_BASE="$sb" LK_TOKEN=S3 LK_BEAT=0.2; lk_heartbeat ) 2>"$T/dualhb.log" &
hb=$!
sleep 1
check_eq "пульс идёт по обоим замкам" "yes yes" \
  "$([ "$(cut -d' ' -f2 "$b/deploy.lock/beat.S3")" -gt 0 ] && echo yes) $([ "$(cut -d' ' -f2 "$sb/deploy.lock/beat.S3")" -gt 0 ] && echo yes)"
rm -rf "$sb/deploy.lock"; hold "$sb" F9
wait_for "$hb" 3
check_eq "отобрали общий замок — пульс останавливается" 1 "$?"
if has "$T/dualhb.log" "$sb/deploy.lock was taken over by org/F9"; then pass "warning называет, какой замок отобран"; else fail "warning называет, какой замок отобран" "$(cat "$T/dualhb.log")"; fi
( LK_BASE="$b" LK_SHARED_BASE="$sb" LK_TOKEN=S3; lk_release_all ) 2>/dev/null
( LK_BASE="$sb" LK_TOKEN=F9; lk_release ) 2>/dev/null

b="$T/held-host"; sb="$T/held-shared"
hold "$sb" F1
( LK_BASE="$b" LK_SHARED_BASE="$sb" LK_TOKEN=A LK_REPO=org/A LK_POLL=0.2 LK_WAIT=20; lk_acquire_all ) 2>/dev/null &
a=$!
until [ "$(tok "$b")" = A ]; do sleep 0.05; done
( LK_BASE="$b" LK_TOKEN=B LK_STALE=2 LK_POLL=0.2 LK_WAIT=20; lk_acquire ) 2>"$T/held.log" &
bpid=$!
sleep 4
check_eq "ожидая общий замок дольше LK_STALE, SSH не теряет замок хоста" A "$(tok "$b")"
if has "$T/held.log" "removed an abandoned lock"; then fail "замок хоста не сняли как брошенный" "$(cat "$T/held.log")"; else pass "замок хоста не сняли как брошенный"; fi
( LK_BASE="$sb" LK_TOKEN=F1; lk_release ) 2>/dev/null
wait_for "$a" 5
check_eq "после освобождения общего SSH получает оба замка" "0 A A" "$? $(tok "$b") $(tok "$sb")"
( LK_BASE="$b" LK_SHARED_BASE="$sb" LK_TOKEN=A; lk_release_all ) 2>/dev/null
wait_for "$bpid" 5
check_eq "следующий SSH получает замок хоста после честного освобождения" "0 B" "$? $(tok "$b")"
( LK_BASE="$b" LK_TOKEN=B; lk_release ) 2>/dev/null

mixed() {
  local host="$1" shared="$2" i
  : > "$Q/done"; rm -f "$Q/viol"; rmdir "$Q/inside" 2>/dev/null
  for i in 1 2 3 4 5 6 7 8; do
    ( if [ $(( i % 2 )) = 0 ]; then LK_BASE="$shared"; LK_SHARED_BASE=""; else LK_BASE="$host"; LK_SHARED_BASE="$shared"; fi
      LK_TOKEN="m$i" LK_POLL=0.05 LK_STALE=100 LK_WAIT=60
      lk_acquire_all 2>/dev/null || { echo "acquire-fail m$i" >> "$Q/viol"; exit 0; }
      mkdir "$Q/inside" 2>/dev/null || echo "overlap m$i" >> "$Q/viol"
      sleep 0.1
      rmdir "$Q/inside"
      echo "m$i" >> "$Q/done"
      lk_release_all 2>/dev/null ) &
  done
  wait
}
q_reset
mixed "$T/mix-host" "$T/mix-shared"
check_eq "смешанная очередь SSH (2 замка) + FTP (общий): все 8 прошли" 8 "$(wc -l < "$Q/done" | tr -d ' ')"
check_eq "смешанная очередь: ни наложений, ни взаимной блокировки" "" "$(cat "$Q/viol" 2>/dev/null)"
check_eq "смешанная очередь: оба замка в конце свободны" "|" "$(tok "$T/mix-host")|$(tok "$T/mix-shared")"

# --- 14–15. разные пользователи одного хоста ------------------------------------------------------
if [ "$(id -u)" = 0 ] && command -v adduser >/dev/null 2>&1 && command -v su >/dev/null 2>&1; then
  for u in lku1 lku2; do id "$u" >/dev/null 2>&1 || adduser -D -s /bin/bash "$u" >/dev/null 2>&1; done

  as() {
    local u="$1"; shift
    su -s /bin/bash "$u" -c ". '$S'; LK_TRANSPORT=local LK_POLL=0.1 LK_WAIT=10 $*"
  }

  XU="$T/xu"
  mkdir -m 1777 "$XU"
  xb="$XU/base"
  as lku1 "LK_BASE='$xb' LK_TOKEN=U1 LK_REPO=org/u1 lk_acquire" 2>/dev/null
  check_eq "u1 взял замок, база принадлежит u1" "0 lku1" "$? $(stat -c %U "$xb")"
  as lku2 "LK_BASE='$xb' LK_TOKEN=U2 LK_STALE=1 lk_acquire" 2>"$T/xuser.log"
  check_eq "u2 снимает брошенный замок u1 (база 0777 без sticky)" "0 U2" "$? $(tok "$xb")"
  as lku2 "LK_BASE='$xb' LK_TOKEN=U2 lk_release" 2>/dev/null
  check_eq "u2 освобождает свой замок" "" "$(tok "$xb")"

  as lku1 "LK_BASE='$xb' LK_TOKEN=U1 LK_REPO=r LK_RUN_NUMBER=5 lk_check_state" 2>/dev/null
  as lku2 "LK_BASE='$xb' LK_TOKEN=U2 LK_REPO=r LK_RUN_NUMBER=6 lk_check_state" 2>/dev/null
  check_eq "u2 перезаписывает запись state, созданную u1" 6 \
    "$(lk_field run_number "$(cat "$xb"/state/* 2>/dev/null)")"

  su -s /bin/sh lku1 -c "mkdir -m 0755 '$XU/x755'"
  as lku2 "LK_BASE='$XU/x755' LK_TOKEN=U2 lk_acquire" 2>"$T/x755.log"
  check_eq "чужая база 0755 — код 2" 2 "$?"
  if has "$T/x755.log" "chmod 0777"; then pass "ошибка подсказывает chmod"; else fail "ошибка подсказывает chmod" "$(cat "$T/x755.log")"; fi

  su -s /bin/sh lku1 -c "mkdir -m 1777 '$XU/x1777'"
  as lku2 "LK_BASE='$XU/x1777' LK_TOKEN=U2 lk_acquire" 2>/dev/null
  check_eq "чужая база со sticky-битом (1777) отвергается" 2 "$?"

  as lku1 "LK_BASE='$XU/x755' LK_TOKEN=U1 lk_acquire" 2>/dev/null
  check_eq "владелец базы сам чинит права до 0777" "0 777" "$? $(stat -c %a "$XU/x755")"

  rm -rf "$XU"
  for u in lku1 lku2; do deluser --remove-home "$u" >/dev/null 2>&1 || true; done
else
  echo "  пропущено: межпользовательские проверки нужны root, adduser и su (идут в контейнере tests/run.sh)"
fi

suite_result "deploy-lock"
