#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/assert.sh
. "$HERE/lib/assert.sh"
# shellcheck source=lib/extract_step.sh
. "$HERE/lib/extract_step.sh"

WF="$ROOT/.github/workflows/ci-cd.yml"

# Без конвейеров вида `printf | grep -q`: grep -q выходит на первом совпадении, printf получает
# SIGPIPE, и при pipefail проверка ложно падает — на Linux это воспроизводится стабильно.

cd_job() { awk '/^  cd:$/{on=1} on && /^  [a-z][a-z0-9_-]*:$/ && !/^  cd:$/{exit} on' "$WF"; }
CD="$(cd_job)"

pos() { awk -v want="$1" 'sub(/^      - name: /, "") { n++; if ($0 == want) { print n; exit } }' <<< "$CD"; }

step_block() {
  awk -v want="      - name: $1" '
    $0 == want { on = 1; print; next }
    on && /^      - name: / { exit }
    on { print }' <<< "$CD"
}

has()   { grep -q  -- "$2" <<< "$1"; }
has_f() { grep -qF -- "$2" <<< "$1"; }

before() {
  local a b
  a="$(pos "$1")"; b="$(pos "$2")"
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then pass "«$1» идёт до «$2»"; else fail "«$1» идёт до «$2»" "позиции: '${a:-нет}' и '${b:-нет}'"; fi
}

before "Keep apt packages for caching" "Install lftp"
before "Install lftp"                  "Acquire deploy lock"
before "Strip .git* from deploy lists" "Acquire deploy lock"
before "Setup SSH auth"                "Acquire deploy lock"
before "Build"                         "Acquire deploy lock"
before "Acquire deploy lock"           "Before deploy command"
before "After deploy command"          "Release deploy lock"
before "Release deploy lock"           "Cleanup"

DEPLOY_STEPS=("Before deploy command" "FTP deploy (full mirror)" "FTP deploy (selective)" \
  "RSYNC deploy (full)" "RSYNC deploy (selective)" "GIT deploy" "After deploy command")

for s in "${DEPLOY_STEPS[@]}"; do
  blk="$(step_block "$s")"
  if has "$blk" "^        if: .*env.DEPLOY_SUPERSEDED != 'true'"; then
    pass "«$s» пропускается у устаревшего запуска"
  else
    fail "«$s» пропускается у устаревшего запуска" "$(grep '^        if:' <<< "$blk")"
  fi
  if has "$blk" "^        timeout-minutes: 60\$"; then
    pass "«$s» ограничен 60 минутами"
  else
    fail "«$s» ограничен 60 минутами"
  fi
done

for s in "FTP deploy (full mirror)" "FTP deploy (selective)"; do
  blk="$(step_block "$s")"
  if has_f "$blk" "apt-get install"; then fail "«$s» больше не ставит lftp сам"; else pass "«$s» больше не ставит lftp сам"; fi
  if has_f "$blk" 'FTP deploy is incomplete' && has_f "$blk" 'exit 1'; then
    pass "«$s» падает, если файлы не залиты после всех попыток"
  else
    fail "«$s» падает, если файлы не залиты после всех попыток"
  fi
done

acq="$(extract_step "$WF" deploy-lock)"
for want in 'lk_acquire_all' 'lk_release_all' 'LK_SHARED_BASE=' 'lk_check_state' 'lk_heartbeat' 'lk_source_from_ref' \
            'DEPLOY_SUPERSEDED=' 'LK_HB_PID=' '# >>> .github/snippets/deploy-lock.sh'; do
  if has_f "$acq" "$want"; then pass "Acquire содержит $want"; else fail "Acquire содержит $want"; fi
done
if awk '/lk_check_state/{c=NR} /lk_heartbeat/{h=NR} END{exit !(c && h && c < h)}' <<< "$acq"; then
  pass "пульс стартует только после проверки устаревания"
else
  fail "пульс стартует только после проверки устаревания"
fi

rel="$(step_block "Release deploy lock")"
if awk '/lk_mark_state ok/{m=NR} /lk_release_all/{r=NR} END{exit !(m && r && m < r)}' <<< "$rel"; then
  pass "Release помечает ok до освобождения"
else
  fail "Release помечает ok до освобождения"
fi

cln="$(step_block "Cleanup")"
for want in 'lk_stop_heartbeat' 'lk_mark_state failed running' 'lk_release_all'; do
  if has_f "$cln" "$want"; then pass "Cleanup вызывает $want"; else fail "Cleanup вызывает $want"; fi
done
if awk '/lk_release/{r=NR} /gt-ssh/{g=NR} /TMP_KEY/{k=k?k:NR} END{exit !(r && g && k && r < g && r < k)}' <<< "$cln"; then
  pass "Cleanup отпускает замок до удаления ключа и SSH-обёртки"
else
  fail "Cleanup отпускает замок до удаления ключа и SSH-обёртки"
fi

env_val() {
  awk -v k="      $1: " 'index($0, k) == 1 { v = substr($0, length(k) + 1); gsub(/\047/, "", v); print v; exit }' <<< "$CD"
}
beat="$(env_val LK_BEAT)"; stale="$(env_val LK_STALE)"; hold="$(env_val LK_MAX_HOLD)"; wait_s="$(env_val LK_WAIT)"
held_steps=3
if [ -n "$hold" ] && [ "$hold" -gt $(( held_steps * 60 * 60 )) ]; then
  pass "LK_MAX_HOLD ($hold с) больше суммы таймаутов шагов под замком (${held_steps}×60 мин)"
else
  fail "LK_MAX_HOLD больше суммы таймаутов шагов под замком" "LK_MAX_HOLD='$hold'"
fi
if [ -n "$wait_s" ] && [ "$wait_s" -gt "${hold:-0}" ]; then pass "LK_WAIT больше LK_MAX_HOLD"; else fail "LK_WAIT больше LK_MAX_HOLD" "$wait_s / $hold"; fi
if [ -n "$stale" ] && [ -n "$beat" ] && [ "$stale" -ge $(( beat * 4 )) ]; then
  pass "LK_STALE ($stale с) переживает минимум 3 пропущенных пульса ($beat с)"
else
  fail "LK_STALE переживает минимум 3 пропущенных пульса" "$stale / $beat"
fi

for v in DEPLOY_LOCK_DIR LK_TRANSPORT LK_REPO LK_WORKFLOW LK_ENVIRONMENT LK_RUN_ID LK_RUN_NUMBER LK_RUN_URL LK_COMMIT LK_SCOPE LK_SSH_TARGET LK_FTP_PASS; do
  if has "$CD" "^      $v: "; then pass "env джобы cd задаёт $v"; else fail "env джобы cd задаёт $v"; fi
done

suite_result "deploy-lock-structure"
