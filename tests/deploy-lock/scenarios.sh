#!/usr/bin/env bash
# shellcheck disable=SC2034  # LK_* читаются функциями подключённого сниппета
set -uo pipefail

# shellcheck source=../lib/assert.sh
. /repo/tests/lib/assert.sh
# shellcheck source=../lib/extract_step.sh
. /repo/tests/lib/extract_step.sh
# shellcheck source=../../.github/snippets/deploy-lock.sh
. /repo/.github/snippets/deploy-lock.sh

W=/tmp/it
rm -rf "$W"; mkdir -p "$W"
trap 'jobs -p | xargs -r kill 2>/dev/null' EXIT

install -m 600 /keys/id_ed25519 "$W/key"
COMMON=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
printf '#!/usr/bin/env bash\nexec ssh -i %q -o IdentitiesOnly=yes -o BatchMode=yes %s "$@"\n' "$W/key" "${COMMON[*]}" > "$W/ssh-dep1"
printf '#!/usr/bin/env bash\nexec sshpass -p pw2 ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no %s "$@"\n' "${COMMON[*]}" > "$W/ssh-dep2"
chmod 700 "$W/ssh-dep1" "$W/ssh-dep2"

for host in sshd ftp; do
  for _ in $(seq 1 60); do
    ip="$(getent hosts "$host" | awk '{print $1; exit}')"
    [ -n "$ip" ] && break
    sleep 0.5
  done
  grep -q " $host\$" /etc/hosts || echo "$ip $host" >> /etc/hosts
done

for _ in $(seq 1 60); do
  "$W/ssh-dep1" dep1@sshd true 2>/dev/null && echo 'ls' | lftp -p 2121 -u ftpu,ftppw ftp >/dev/null 2>&1 && break
  sleep 0.5
done

LK_POLL=0.2
LK_WAIT=60
LK_LOG_EVERY=100000

as_ssh() { LK_TRANSPORT=ssh; LK_SSH="$W/ssh-$1"; LK_SSH_TARGET="$1@sshd"; }
as_ftp() { LK_TRANSPORT=ftp; LK_FTP_HOST=ftp; LK_FTP_PORT=2121; LK_FTP_USER=ftpu; LK_FTP_PASS=ftppw; }

remote() { "$W/ssh-dep1" dep1@sshd "$@"; }
ftp_ls() { printf 'cls -a -1 %s\n' "$1" | timeout 30 lftp -p 2121 -u ftpu,ftppw ftp 2>/dev/null; }
tok_of() { lk_field token "$(lkt_read deploy.lock/owner 2>/dev/null)" || true; }

remote "rm -rf /tmp/git_toolkit" 2>/dev/null
printf 'rm -r -f .git_toolkit
' | lftp -p 2121 -u ftpu,ftppw ftp >/dev/null 2>&1

wait_for() {
  local pid="$1" n=$(( $2 * 10 ))
  while kill -0 "$pid" 2>/dev/null && [ "$n" -gt 0 ]; do sleep 0.1; n=$(( n - 1 )); done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124; fi
  wait "$pid"
}

queue() {
  local transport="$1" n="$2" i who
  : > "$W/done"; rm -f "$W/viol"; rmdir "$W/inside" 2>/dev/null
  for i in $(seq 1 "$n"); do
    who=dep1; [ $(( i % 2 )) = 0 ] && who=dep2
    ( if [ "$transport" = ssh ]; then as_ssh "$who"; else as_ftp; fi
      LK_TOKEN="q$i" LK_REPO="org/q$i" LK_BEAT=1 LK_STALE=6 LK_POLL=0.3 LK_WAIT=120
      lk_acquire 2>>"$W/q$i.log" || { echo "acquire-fail q$i" >> "$W/viol"; exit 0; }
      lk_heartbeat 2>>"$W/q$i.log" &
      hb=$!
      mkdir "$W/inside" 2>/dev/null || echo "overlap q$i" >> "$W/viol"
      sleep 0.3
      rmdir "$W/inside"
      echo "q$i" >> "$W/done"
      kill "$hb" 2>/dev/null; wait "$hb" 2>/dev/null
      lk_release 2>>"$W/q$i.log" ) &
  done
  wait
}

echo "-- ssh --"

( as_ssh dep1; LK_TOKEN=S1 LK_REPO=org/s1; lk_acquire ) 2>/dev/null
check_eq "ssh: dep1 берёт замок на сервере" "S1 dep1 777" \
  "$( as_ssh dep1; tok_of) $(remote "stat -c '%U %a' /tmp/git_toolkit/deploy.lock")"
( as_ssh dep2; LK_TOKEN=S2; lk_release ) 2>"$W/s-rel.log"
check_eq "ssh: dep2 не может отпустить чужой замок" S1 "$( as_ssh dep1; tok_of)"
( as_ssh dep1; LK_TOKEN=S1; lk_release ) 2>/dev/null
check_eq "ssh: dep1 отпускает свой" "" "$( as_ssh dep1; tok_of)"

queue ssh 6
check_eq "ssh: 6 деплоев двух пользователей прошли по очереди" 6 "$(wc -l < "$W/done" | tr -d ' ')"
check_eq "ssh: ни одного наложения" "" "$(cat "$W/viol" 2>/dev/null)"
check_eq "ssh: ложных снятий нет" 0 "$(cat "$W"/q*.log | grep -c 'removed an abandoned lock')"
rm -f "$W"/q*.log

( as_ssh dep1; LK_TOKEN=H1 LK_REPO=org/h1; lk_acquire ) 2>/dev/null
( as_ssh dep1; LK_TOKEN=H1 LK_BEAT=1; lk_heartbeat ) 2>/dev/null &
hb=$!
( as_ssh dep2; LK_TOKEN=H2 LK_STALE=4 LK_POLL=0.3; lk_acquire ) 2>"$W/h2.log" &
pid=$!
sleep 6
check_eq "ssh: живой пульс dep1 держит замок дольше LK_STALE" H1 "$( as_ssh dep1; tok_of)"
kill -9 "$hb"; wait "$hb" 2>/dev/null
wait_for "$pid" 15
check_eq "ssh: пульс убит — dep2 снимает замок dep1" "0 H2" "$? $( as_ssh dep1; tok_of)"
if grep -q "org/h1" "$W/h2.log"; then pass "ssh: warning о снятии называет dep1-деплой"; else fail "ssh: warning о снятии называет dep1-деплой" "$(cat "$W/h2.log")"; fi
( as_ssh dep2; LK_TOKEN=H2; lk_release ) 2>/dev/null
check_eq "ssh: после снятия на сервере нет мусора" "" "$(remote ls /tmp/git_toolkit | grep '^deploy.lock')"

st() { ( as_ssh "$1"; LK_REPO=org/app LK_WORKFLOW=w LK_ENVIRONMENT=main LK_SOURCE=branch:main
         LK_RUN_NUMBER="$2" LK_RUN_ID="r$2" LK_SCOPE="$3" LK_TOKEN="t$2"
         lk_check_state 2>/dev/null || exit $?
         [ "$4" = ok ] && lk_mark_state ok
         printf '%s' "$LK_SUPERSEDED" ); printf ':%s ' "$?"; }
got="$(st dep1 7 full ok)$(st dep2 5 full ok)$(st dep2 8 selective fail)$(st dep1 9 selective ok)$(st dep1 10 full ok)"
check_eq "ssh: устаревание и незавершённый деплой между пользователями" \
  "false:0 true:0 false:0 :3 false:0 " "$got"

( LK_TRANSPORT=ssh LK_SSH="$W/ssh-dep1" LK_SSH_TARGET="dep1@nohost.invalid" LK_TOKEN=X LK_WAIT=5; lk_acquire ) 2>"$W/nohost.log"
check_eq "ssh: недоступный сервер — код 2 без зависания" 2 "$?"

echo "-- ftp --"

( as_ftp; LK_TOKEN=F1 LK_REPO=org/f1; lk_acquire ) 2>/dev/null
check_eq "ftp: замок берётся" F1 "$( as_ftp; tok_of)"
( as_ftp; LK_TOKEN=F2 LK_WAIT=2 LK_POLL=0.5; lk_acquire ) 2>"$W/f2.log"
check_eq "ftp: второй ждёт и отваливается по таймауту" 1 "$?"
if grep -q "org/f1" "$W/f2.log"; then pass "ftp: ожидающий видит держателя"; else fail "ftp: ожидающий видит держателя" "$(cat "$W/f2.log")"; fi
( as_ftp; LK_TOKEN=F1; lk_release ) 2>/dev/null
check_eq "ftp: замок отпущен" "" "$( as_ftp; tok_of)"

queue ftp 4
check_eq "ftp: 4 параллельных FTP-деплоя прошли по очереди" 4 "$(wc -l < "$W/done" | tr -d ' ')"
check_eq "ftp: ни одного наложения" "" "$(cat "$W/viol" 2>/dev/null)"
rm -f "$W"/q*.log

( as_ftp; LK_TOKEN=D1 LK_REPO=org/dead; lk_acquire ) 2>/dev/null
( as_ftp; LK_TOKEN=D2 LK_STALE=3 LK_POLL=0.5; lk_acquire ) 2>"$W/d2.log"
check_eq "ftp: брошенный замок снимается через RNFR/RNTO" "0 D2" "$? $( as_ftp; tok_of)"
( as_ftp; LK_TOKEN=D2; lk_release ) 2>/dev/null
check_eq "ftp: мусора после снятия нет" "" "$(ftp_ls .git_toolkit | grep '^deploy.lock')"

( as_ftp; LK_TOKEN=Z1 LK_REPO=org/hung; lk_acquire ) 2>/dev/null
( as_ftp; LK_TOKEN=Z1 LK_BEAT=1; lk_heartbeat ) 2>"$W/z1.log" &
hb=$!
( as_ftp; LK_TOKEN=Z2 LK_STALE=4 LK_POLL=0.5; lk_acquire ) 2>"$W/z2.log" &
pid=$!
sleep 6
check_eq "ftp: пока пульс идёт, замок у держателя" Z1 "$( as_ftp; tok_of)"
kill -STOP "$hb"
pkill -STOP -P "$hb" 2>/dev/null
wait_for "$pid" 20
check_eq "ftp: зависший держатель (SIGSTOP) — замок снят" "0 Z2" "$? $( as_ftp; tok_of)"
pkill -CONT -P "$hb" 2>/dev/null
kill -CONT "$hb"
wait_for "$hb" 10
check_eq "ftp: очнувшийся пульс видит, что замок отобран, и выходит" 1 "$?"
if grep -q "taken over" "$W/z1.log"; then pass "ftp: warning о потере замка"; else fail "ftp: warning о потере замка" "$(cat "$W/z1.log")"; fi
( as_ftp; LK_TOKEN=Z2; lk_release ) 2>/dev/null

st() { ( as_ftp; LK_REPO=org/app LK_WORKFLOW=w LK_ENVIRONMENT=main LK_SOURCE=branch:main
         LK_RUN_NUMBER="$1" LK_RUN_ID="r$1" LK_SCOPE="$2" LK_TOKEN="t$1"
         lk_check_state 2>/dev/null || exit $?
         case "$3" in ok) lk_mark_state ok ;; fail) lk_mark_state failed running ;; esac
         printf '%s' "$LK_SUPERSEDED" ); printf ':%s ' "$?"; }
got="$(st 1 full ok)$(st 2 selective fail)$(st 3 selective ok)$(st 4 full ok)$(st 2 full ok)"
check_eq "ftp: сбой → selective блок → full чинит → устаревший пропущен" \
  "false:0 false:0 :3 false:0 true:0 " "$got"

started=$(date +%s)
( LK_TRANSPORT=ftp LK_FTP_HOST=nohost.invalid LK_FTP_USER=u LK_TOKEN=X LK_WAIT=5 LK_FTP_OP_TIMEOUT=10; lk_acquire ) 2>/dev/null
check_eq "ftp: недоступный сервер — код 2" 2 "$?"
took=$(( $(date +%s) - started ))
if [ "$took" -le 30 ]; then pass "ftp: недоступный сервер не вешает очередь ($took с)"; else fail "ftp: недоступный сервер не вешает очередь" "$took с"; fi

echo "-- ssh + ftp, общий каталог --"

SHARED_SSH=/srv/shared/.git_toolkit
SHARED_FTP=shared/.git_toolkit
remote2() { "$W/ssh-dep2" dep2@sshd "$@"; }
remote "rm -rf $SHARED_SSH" 2>/dev/null
as_ssh_sh() { as_ssh "$1"; LK_SHARED_BASE="$SHARED_SSH"; }
as_ftp_sh() { as_ftp; LK_BASE="$SHARED_FTP"; }
sh_tok() { ( as_ftp_sh; tok_of ); }

( as_ftp_sh; LK_TOKEN=X1 LK_REPO=org/ftp-app; lk_acquire ) 2>/dev/null
check_eq "общий: FTP-замок виден SSH-пользователю на диске, права 0777" "X1 777" \
  "$(sh_tok) $(remote2 "stat -c %a $SHARED_SSH/deploy.lock")"
( as_ssh_sh dep2; LK_TOKEN=X2 LK_WAIT=3 LK_POLL=0.5; lk_acquire_all ) 2>"$W/x2.log"
check_eq "общий: SSH ждёт FTP-держателя и по таймауту отпускает замок хоста" "1 " "$? $( as_ssh dep2; tok_of)"
if grep -q "org/ftp-app" "$W/x2.log"; then pass "общий: SSH в логе видит FTP-деплой"; else fail "общий: SSH в логе видит FTP-деплой" "$(cat "$W/x2.log")"; fi

( as_ssh_sh dep2; LK_TOKEN=X3 LK_STALE=3 LK_POLL=0.5; lk_acquire_all ) 2>"$W/x3.log"
check_eq "общий: SSH-пользователь с другим uid снимает брошенный FTP-замок" "0 X3" "$? $(sh_tok)"
if grep -q "removed an abandoned lock.*org/ftp-app" "$W/x3.log"; then pass "общий: warning называет FTP-деплой"; else fail "общий: warning называет FTP-деплой" "$(cat "$W/x3.log")"; fi

( as_ftp_sh; LK_TOKEN=X4 LK_STALE=3 LK_POLL=0.5; lk_acquire ) 2>"$W/x4.log"
check_eq "общий: FTP снимает брошенный SSH-замок в общем каталоге" "0 X4" "$? $(sh_tok)"
( as_ftp_sh; LK_TOKEN=X4; lk_release ) 2>/dev/null
( as_ssh dep2; LK_TOKEN=X3; lk_release ) 2>/dev/null
check_eq "общий: после снятий нет мусора" "" "$(remote "ls -a $SHARED_SSH" | grep '^deploy.lock')"

: > "$W/done"; rm -f "$W/viol"; rmdir "$W/inside" 2>/dev/null
for i in 1 2 3 4 5 6; do
  ( case $(( i % 3 )) in
      0) as_ftp_sh ;;
      1) as_ssh_sh dep1 ;;
      2) as_ssh_sh dep2 ;;
    esac
    LK_TOKEN="x$i" LK_REPO="org/x$i" LK_BEAT=1 LK_STALE=8 LK_POLL=0.3 LK_WAIT=120
    lk_acquire_all 2>>"$W/mq$i.log" || { echo "acquire-fail x$i" >> "$W/viol"; exit 0; }
    lk_heartbeat 2>>"$W/mq$i.log" &
    hb=$!
    mkdir "$W/inside" 2>/dev/null || echo "overlap x$i" >> "$W/viol"
    sleep 0.3
    rmdir "$W/inside"
    echo "x$i" >> "$W/done"
    kill "$hb" 2>/dev/null; wait "$hb" 2>/dev/null
    lk_release_all 2>>"$W/mq$i.log" ) &
done
wait
check_eq "общий: 2 SSH-пользователя и FTP в одной очереди — все 6 прошли" 6 "$(wc -l < "$W/done" | tr -d ' ')"
check_eq "общий: ни наложений, ни взаимной блокировки" "" "$(cat "$W/viol" 2>/dev/null)"
check_eq "общий: ложных снятий нет" 0 "$(cat "$W"/mq[1-6].log | grep -c 'removed an abandoned lock')"

echo "-- ftp deploy steps --"

run_ftp_step() {
  local scope="$1" scope_dir="$W/step-$1"
  rm -rf "$scope_dir"; mkdir -p "$scope_dir/src/sub" "$scope_dir/src/ro" "$scope_dir/tmp"
  echo ok1 > "$scope_dir/src/ok1.txt"
  echo ok2 > "$scope_dir/src/sub/ok2.txt"
  echo bad > "$scope_dir/src/ro/bad.txt"
  printf '%s\n' ok1.txt sub/ok2.txt ro/bad.txt > "$scope_dir/tmp/files_upload.txt"
  : > "$scope_dir/tmp/files_delete.txt"
  extract_step /repo/.github/workflows/ci-cd.yml deploy-ftp > "$scope_dir/step.sh"
  ( cd "$scope_dir/src" && env -i PATH="$PATH" HOME=/tmp RUNNER_TEMP="$scope_dir/tmp" \
      DEPLOY_HOST=ftp DEPLOY_PORT=2121 DEPLOY_USER=ftpu DEPLOY_KEY=ftppw DEPLOY_PATH="site" \
      DEPLOY_LOCAL_DIR=./ DEPLOY_MIRROR=false SCOPE="$scope" \
      timeout 240 bash "$scope_dir/step.sh" ) > "$scope_dir/out.log" 2>&1
}

for id in selective full; do
  printf 'rm -r -f site/ok1.txt site/sub\n' | lftp -p 2121 -u ftpu,ftppw ftp >/dev/null 2>&1
  run_ftp_step "$id"
  code=$?
  check_eq "$id: недоливка по FTP роняет шаг" 1 "$code"
  if grep -q "FTP deploy is incomplete" "$W/step-$id/out.log" && grep -q "ro/bad.txt" "$W/step-$id/out.log"; then
    pass "$id: ошибка перечисляет не залитые файлы"
  else
    fail "$id: ошибка перечисляет не залитые файлы" "$(tail -20 "$W/step-$id/out.log")"
  fi
  check_eq "$id: всё, что можно, залито" "ok1 ok2" \
    "$(printf 'cat site/ok1.txt\ncat site/sub/ok2.txt\n' | lftp -p 2121 -u ftpu,ftppw ftp 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
done

suite_result "deploy-lock-integration"
