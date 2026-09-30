LK_BASE="${LK_BASE:-}"
LK_TRANSPORT="${LK_TRANSPORT:-local}"
LK_BEAT="${LK_BEAT:-15}"
LK_STALE="${LK_STALE:-90}"
LK_WAIT="${LK_WAIT:-1800}"
LK_MAX_HOLD="${LK_MAX_HOLD:-3600}"
LK_POLL="${LK_POLL:-10}"
LK_LOG_EVERY="${LK_LOG_EVERY:-60}"
LK_TOKEN="${LK_TOKEN:-}"
LK_SHARED_BASE="${LK_SHARED_BASE:-}"
LK_SUPERSEDED="${LK_SUPERSEDED:-false}"

lk_now()   { date +%s; }
lk_sleep() { sleep "$1"; }
lk_log()   { printf '%s\n' "$*" >&2; }

lk_base() {
  if [ -n "$LK_BASE" ]; then printf '%s' "$LK_BASE"
  elif [ "$LK_TRANSPORT" = "ftp" ]; then printf '.git_toolkit'
  else printf '/tmp/git_toolkit'
  fi
}

lk__fs_ensure_base() {
  local b="$1" d mode
  umask 000
  for d in "$b" "$b/state"; do
    mkdir -m 0777 "$d" 2>/dev/null || true
    if [ ! -d "$d" ]; then
      echo "::error::Deploy lock: cannot create '$d'." >&2
      return 2
    fi
    mode="$(stat -c %a "$d" 2>/dev/null || echo '?')"
    if [ "$mode" != "777" ] && [ -O "$d" ]; then
      chmod 0777 "$d" 2>/dev/null && mode=777
    fi
    if [ "$mode" != "777" ]; then
      echo "::error::Deploy lock: '$d' has mode $mode and belongs to another user; other deploy users could not take over its stale locks. Fix once on the server: chmod 0777 '$d'" >&2
      return 2
    fi
  done
}

lk__fs_mkdir() {
  umask 000
  if mkdir -m 0777 "$1/$2" 2>/dev/null; then return 0; fi
  if [ -e "$1/$2" ]; then return 1; fi
  return 2
}

lk__fs_read() { cat "$1/$2" 2>/dev/null; }

lk__fs_write() {
  local f="$1/$2"
  umask 000
  cat > "$f.tmp.$$" 2>/dev/null && mv -f "$f.tmp.$$" "$f" 2>/dev/null && return 0
  rm -f "$f.tmp.$$" 2>/dev/null
  return 1
}

lk__fs_rename() { mv -T "$1/$2" "$1/$3" 2>/dev/null; }

lk__fs_rmtree() { rm -rf "${1:?}/${2:?}" 2>/dev/null; }

lk__ssh() {
  local fn="$1" rc=0 script guard=()
  shift
  script="$(declare -f "$fn")"$'\n'
  if [ -n "${LK__DATA+x}" ]; then
    script+="printf '%s' $(printf '%q' "$LK__DATA") | "
  fi
  script+="$(printf '%q ' "$fn" "$(lk_base)" "$@")"$'\n'
  command -v timeout >/dev/null 2>&1 && guard=(timeout -k 5 "${LK_SSH_OP_TIMEOUT:-90}")
  "${guard[@]}" "${LK_SSH:?LK_SSH is not set}" "${LK_SSH_TARGET:?LK_SSH_TARGET is not set}" bash -s <<< "$script" || rc=$?
  case "$rc" in 124|137|255) rc=2 ;; esac
  return "$rc"
}

lk__ftp() {
  local guard=()
  command -v timeout >/dev/null 2>&1 && guard=(timeout -k 5 "${LK_FTP_OP_TIMEOUT:-90}")
  {
    printf '%s\n' \
      "set net:timeout 20" \
      "set net:max-retries 2" \
      "set net:reconnect-interval-base 3" \
      "set dns:fatal-timeout 15" \
      "set ftp:passive-mode true" \
      "set ssl:verify-certificate no"
    cat
    echo "quit"
  } | "${guard[@]}" lftp -u "${LK_FTP_USER:?LK_FTP_USER is not set},${LK_FTP_PASS:-}" -p "${LK_FTP_PORT:-21}" "${LK_FTP_HOST:?LK_FTP_HOST is not set}"
}

lk__ftp_path() { printf '"%s/%s"' "$(lk_base)" "$1"; }

lkt_ensure_base() {
  case "$LK_TRANSPORT" in
    local) lk__fs_ensure_base "$(lk_base)" ;;
    ssh)   lk__ssh lk__fs_ensure_base ;;
    ftp)
      printf 'mkdir -p %s\n' "$(lk__ftp_path state)" | lk__ftp >/dev/null 2>&1 || true
      printf 'chmod 777 "%s"\nchmod 777 %s\n' "$(lk_base)" "$(lk__ftp_path state)" | lk__ftp >/dev/null 2>&1 || true
      if ! printf 'cd %s\n' "$(lk__ftp_path state)" | lk__ftp >/dev/null 2>&1; then
        echo "::error::Deploy lock: cannot create '$(lk_base)/state' over FTP." >&2
        return 2
      fi
      ;;
    *) echo "::error::Deploy lock: unknown transport '$LK_TRANSPORT'." >&2; return 2 ;;
  esac
}

lkt_mkdir() {
  case "$LK_TRANSPORT" in
    local) lk__fs_mkdir "$(lk_base)" "$1" ;;
    ssh)   lk__ssh lk__fs_mkdir "$1" ;;
    ftp)
      if printf 'mkdir %s\n' "$(lk__ftp_path "$1")" | lk__ftp >/dev/null 2>&1; then
        printf 'chmod 777 %s\n' "$(lk__ftp_path "$1")" | lk__ftp >/dev/null 2>&1 || true
        return 0
      fi
      if printf 'cd %s\n' "$(lk__ftp_path state)" | lk__ftp >/dev/null 2>&1; then return 1; fi
      return 2
      ;;
  esac
}

lkt_read() {
  case "$LK_TRANSPORT" in
    local) lk__fs_read "$(lk_base)" "$1" ;;
    ssh)   lk__ssh lk__fs_read "$1" ;;
    ftp)   printf 'cat %s\n' "$(lk__ftp_path "$1")" | lk__ftp 2>/dev/null ;;
  esac
}

lkt_write() {
  local LK__DATA rc=0 tmp
  LK__DATA="$(cat)"$'\n'
  case "$LK_TRANSPORT" in
    local) printf '%s' "$LK__DATA" | lk__fs_write "$(lk_base)" "$1" ;;
    ssh)   lk__ssh lk__fs_write "$1" ;;
    ftp)
      tmp="$(mktemp)"
      printf '%s' "$LK__DATA" > "$tmp"
      printf 'put %s -o %s\n' "$tmp" "$(lk__ftp_path "$1")" | lk__ftp >/dev/null 2>&1 || rc=$?
      rm -f "$tmp"
      return "$rc"
      ;;
  esac
}

lkt_rename() {
  case "$LK_TRANSPORT" in
    local) lk__fs_rename "$(lk_base)" "$1" "$2" ;;
    ssh)   lk__ssh lk__fs_rename "$1" "$2" ;;
    ftp)   printf 'mv %s %s\n' "$(lk__ftp_path "$1")" "$(lk__ftp_path "$2")" | lk__ftp >/dev/null 2>&1 ;;
  esac
}

lkt_rmtree() {
  case "$LK_TRANSPORT" in
    local) lk__fs_rmtree "$(lk_base)" "$1" ;;
    ssh)   lk__ssh lk__fs_rmtree "$1" ;;
    ftp)
      {
        [ -n "${2:-}" ] && printf 'rm -f %s\n' "$(lk__ftp_path "$1/beat.$2")"
        printf 'rm -f %s\nrmdir %s\n' "$(lk__ftp_path "$1/owner")" "$(lk__ftp_path "$1")"
      } | lk__ftp >/dev/null 2>&1 && return 0
      printf 'rm -r -f %s\n' "$(lk__ftp_path "$1")" | lk__ftp >/dev/null 2>&1
      ;;
  esac
}

lk__clean() { local v="${1:-}"; v="${v//$'\r'/}"; printf '%s' "${v//$'\n'/ }"; }

lk_field() {
  local want="$1" line
  while IFS= read -r line; do
    if [ "${line%%=*}" = "$want" ]; then printf '%s' "${line#*=}"; return 0; fi
  done <<< "${2:-}"
  return 1
}

lk__token() {
  local b
  if [ -r /dev/urandom ]; then b="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"; else b="$$$RANDOM"; fi
  printf '%s-%s-%s' "${LK_RUN_ID:-local}" "${LK_RUN_ATTEMPT:-1}" "$b"
}

lk__owner_text() {
  local k v n
  for k in token repo workflow environment source run_id run_number run_attempt run_url commit actor deploy_user method acquired_at; do
    case "$k" in
      token)       v="$LK_TOKEN" ;;
      acquired_at) v="$(lk_now)" ;;
      *)           n="LK_${k^^}"; v="${!n:-}" ;;
    esac
    printf '%s=%s\n' "$k" "$(lk__clean "$v")"
  done
}

lk_describe() {
  local o="${1:-}" repo env num url commit user method since held=""
  if [ -z "$o" ]; then printf 'unknown owner (no owner file)'; return 0; fi
  repo="$(lk_field repo "$o" || true)"
  env="$(lk_field environment "$o" || true)"
  num="$(lk_field run_number "$o" || true)"
  url="$(lk_field run_url "$o" || true)"
  commit="$(lk_field commit "$o" || true)"
  user="$(lk_field deploy_user "$o" || true)"
  method="$(lk_field method "$o" || true)"
  since="$(lk_field acquired_at "$o" || true)"
  case "$since" in ''|*[!0-9]*) ;; *) held=", held ~$(( $(lk_now) - since ))s" ;; esac
  printf '%s [%s] run #%s %s, commit %s, user %s, method %s%s' \
    "${repo:-?}" "${env:-?}" "${num:-?}" "${url:-?}" "${commit:0:7}" "${user:-?}" "${method:-?}" "$held"
}

lk__steal() {
  local expect="$1" o tomb got
  tomb="deploy.lock.stale.$LK_TOKEN"
  o="$(lkt_read deploy.lock/owner || true)"
  [ "$(lk_field token "$o" || true)" = "$expect" ] || return 1
  lkt_rename deploy.lock "$tomb" || return 1
  got="$(lk_field token "$(lkt_read "$tomb/owner" || true)" || true)"
  if [ "$got" != "$expect" ]; then
    lkt_rename "$tomb" deploy.lock || lk_log "::warning::Deploy lock: a fresh lock was moved aside by mistake and could not be put back ($(lk_base)/$tomb)."
    return 1
  fi
  lkt_rmtree "$tomb" "$expect" || true
  lk_log "::warning::Deploy lock: removed an abandoned lock (no heartbeat for ${LK_STALE}s): $(lk_describe "$o")"
  return 0
}

lk__keep_held() {
  local rc=0
  [ -n "${LK_HELD_BASE:-}" ] || return 0
  LK_BASE="$LK_HELD_BASE" lk__beat_once "w$1" || rc=$?
  if [ "$rc" -eq 1 ]; then
    echo "::error::Deploy lock: lost $LK_HELD_BASE/deploy.lock while waiting for $(lk_base)/deploy.lock." >&2
    return 1
  fi
  return 0
}

lk_acquire() {
  local start now rc o beat key seen_key="" seen_at=0 last_log=0 tok held=0
  lkt_ensure_base || return 2
  [ -n "$LK_TOKEN" ] || LK_TOKEN="$(lk__token)"
  start="$(lk_now)"
  while :; do
    rc=0; lkt_mkdir deploy.lock || rc=$?
    if [ "$rc" -eq 0 ]; then
      if ! lk__owner_text | lkt_write deploy.lock/owner; then
        lkt_rmtree deploy.lock "$LK_TOKEN" || true
        echo "::error::Deploy lock: cannot write the owner file into $(lk_base)/deploy.lock." >&2
        return 2
      fi
      printf '%s 0' "$LK_TOKEN" | lkt_write "deploy.lock/beat.$LK_TOKEN" || true
      lk_log "Deploy lock acquired: $(lk_base)/deploy.lock (token $LK_TOKEN, waited $(( $(lk_now) - start ))s)"
      return 0
    fi
    if [ "$rc" -ne 1 ]; then
      if [ $(( $(lk_now) - start )) -ge "$LK_WAIT" ]; then
        echo "::error::Deploy lock: gave up after ${LK_WAIT}s — cannot create $(lk_base)/deploy.lock." >&2
        return 2
      fi
      lkt_ensure_base || return 2
      held=$(( held + 1 )); lk__keep_held "$held" || return 2
      lk_sleep "$LK_POLL"
      continue
    fi

    o="$(lkt_read deploy.lock/owner || true)"
    tok="$(lk_field token "$o" || true)"
    beat=""
    [ -n "$tok" ] && beat="$(lkt_read "deploy.lock/beat.$tok" || true)"
    now="$(lk_now)"
    key="$tok|$beat"

    if [ "$key" != "$seen_key" ]; then
      if [ "${seen_key%%|*}" != "$tok" ] || [ -z "$seen_key" ]; then
        lk_log "Waiting for the deploy lock: $(lk_describe "$o")"
        last_log="$now"
      fi
      seen_key="$key"; seen_at="$now"
    elif [ $(( now - seen_at )) -ge "$LK_STALE" ]; then
      if lk__steal "$tok"; then seen_key=""; continue; fi
      seen_key=""
    fi

    if [ $(( now - start )) -ge "$LK_WAIT" ]; then
      echo "::error::Deploy lock: gave up after ${LK_WAIT}s. The lock is held by: $(lk_describe "$o"). If that run is dead, remove $(lk_base)/deploy.lock on the server." >&2
      return 1
    fi
    if [ $(( now - last_log )) -ge "$LK_LOG_EVERY" ]; then
      lk_log "Still waiting ($(( now - start ))s): $(lk_describe "$o")"
      last_log="$now"
    fi
    held=$(( held + 1 )); lk__keep_held "$held" || return 2
    lk_sleep "$LK_POLL"
  done
}

lk__beat_once() {
  local o tok
  o="$(lkt_read deploy.lock/owner)" || return 2
  tok="$(lk_field token "$o" || true)"
  if [ "$tok" != "$LK_TOKEN" ]; then
    lk_log "::warning::Deploy lock: $(lk_base)/deploy.lock was taken over by $(lk_describe "$o") — heartbeat stopped."
    return 1
  fi
  printf '%s %s' "$LK_TOKEN" "$1" | lkt_write "deploy.lock/beat.$LK_TOKEN" || return 2
}

lk_heartbeat() {
  local seq=0 fails=0 start rc
  start="$(lk_now)"
  while :; do
    lk_sleep "$LK_BEAT"
    if [ $(( $(lk_now) - start )) -ge "$LK_MAX_HOLD" ]; then
      lk_log "::warning::Deploy lock: held for over ${LK_MAX_HOLD}s — heartbeat stopped, the next deploy may take the lock over in ${LK_STALE}s."
      return 0
    fi
    seq=$(( seq + 1 ))
    rc=0
    lk__beat_once "$seq" || rc=$?
    if [ "$rc" -eq 0 ] && [ -n "${LK_SHARED_BASE:-}" ]; then
      LK_BASE="$LK_SHARED_BASE" lk__beat_once "$seq" || rc=$?
    fi
    case "$rc" in
      0) fails=0 ;;
      1) return 1 ;;
      *)
        fails=$(( fails + 1 ))
        if [ "$fails" -ge 3 ]; then
          lk_log "::warning::Deploy lock: heartbeat failed 3 times in a row — stopped."
          return 1
        fi
        ;;
    esac
  done
}

lk_release() {
  local o tok tomb got
  [ -n "$LK_TOKEN" ] || return 0
  o="$(lkt_read deploy.lock/owner || true)"
  tok="$(lk_field token "$o" || true)"
  if [ "$tok" != "$LK_TOKEN" ]; then
    [ -n "$o" ] && lk_log "::warning::Deploy lock: not released — it now belongs to $(lk_describe "$o")."
    return 0
  fi
  tomb="deploy.lock.done.$LK_TOKEN"
  lkt_rename deploy.lock "$tomb" || { lk_log "::warning::Deploy lock: cannot release $(lk_base)/deploy.lock."; return 1; }
  got="$(lk_field token "$(lkt_read "$tomb/owner" || true)" || true)"
  if [ "$got" != "$LK_TOKEN" ]; then
    lkt_rename "$tomb" deploy.lock || true
    return 0
  fi
  lkt_rmtree "$tomb" "$LK_TOKEN" || true
  lk_log "Deploy lock released: $(lk_base)/deploy.lock"
}

lk_acquire_all() {
  local rc=0
  lk_acquire || return $?
  [ -n "${LK_SHARED_BASE:-}" ] || return 0
  LK_HELD_BASE="$(lk_base)" LK_BASE="$LK_SHARED_BASE" lk_acquire || rc=$?
  if [ "$rc" -ne 0 ]; then
    lk_release || true
    return "$rc"
  fi
}

lk_release_all() {
  local rc=0
  if [ -n "${LK_SHARED_BASE:-}" ]; then
    LK_BASE="$LK_SHARED_BASE" lk_release || rc=$?
  fi
  lk_release || rc=$?
  return "$rc"
}

lk__workflow() { local w="${LK_WORKFLOW:-}"; printf '%s' "${w%@*}"; }

lk_source_from_ref() {
  local name="${REF_NAME:-}"
  case "${REF_TYPE:-}" in
    branch) printf 'branch:%s' "${name//\//-}" ;;
    tag)
      if [ "${name#*/}" != "$name" ]; then
        name="${name%/*}"
        printf 'branch:%s' "${name//\//-}"
      else
        printf 'branch:%s' "${REF_BRANCH:-}"
      fi
      ;;
    pr) printf '%s' "${REF_NAME_NORM:-}" ;;
    *)  printf '%s:%s' "${REF_TYPE:-}" "$name" ;;
  esac
}

lk_state_key() {
  printf '%s|%s|%s|%s' "${LK_REPO:-}" "$(lk__workflow)" "${LK_ENVIRONMENT:-}" "${LK_SOURCE:-}" | sha1sum | cut -c1-40
}

lk__state_text() {
  printf 'repo=%s\n'        "$(lk__clean "${LK_REPO:-}")"
  printf 'workflow=%s\n'    "$(lk__clean "$(lk__workflow)")"
  printf 'environment=%s\n' "$(lk__clean "${LK_ENVIRONMENT:-}")"
  printf 'source=%s\n'      "$(lk__clean "${LK_SOURCE:-}")"
  printf 'scope=%s\n'       "$(lk__clean "${LK_SCOPE:-}")"
  printf 'run_id=%s\n'      "$(lk__clean "${LK_RUN_ID:-}")"
  printf 'run_number=%s\n'  "$LK_RUN_NUMBER"
  printf 'run_attempt=%s\n' "$(lk__clean "${LK_RUN_ATTEMPT:-}")"
  printf 'run_url=%s\n'     "$(lk__clean "${LK_RUN_URL:-}")"
  printf 'commit=%s\n'      "$(lk__clean "${LK_COMMIT:-}")"
  printf 'at=%s\n'          "$(lk_now)"
  printf 'token=%s\n'       "$LK_TOKEN"
  printf 'status=%s\n'      "$1"
}

lk_check_state() {
  local key rec prev status prev_id what
  LK_SUPERSEDED=false
  case "${LK_RUN_NUMBER:-}" in ''|*[!0-9]*) return 0 ;; esac
  key="$(lk_state_key)"
  rec="$(lkt_read "state/$key" || true)"
  prev="$(lk_field run_number "$rec" || true)"
  case "$prev" in ''|*[!0-9]*) prev="" ;; esac
  if [ -n "$prev" ] && [ "$prev" -gt "$LK_RUN_NUMBER" ]; then
    LK_SUPERSEDED=true
    lk_log "::notice::Deploy skipped: a newer run #$prev already deployed ${LK_REPO:-?} [${LK_ENVIRONMENT:-?}, ${LK_SOURCE:-?}] (commit $(lk_field commit "$rec" | cut -c1-7), $(lk_field run_url "$rec" || true)). This run is #$LK_RUN_NUMBER. To roll back on purpose, start a new run via workflow_dispatch."
    return 0
  fi

  status="$(lk_field status "$rec" || true)"
  prev_id="$(lk_field run_id "$rec" || true)"
  if [ "$status" = running ] || [ "$status" = failed ]; then
    what="the previous deploy #${prev:-?} ($(lk_field run_url "$rec" || true), commit $(lk_field commit "$rec" | cut -c1-7)) did not complete (status: $status)"
    if [ -n "$prev_id" ] && [ "$prev_id" = "${LK_RUN_ID:-}" ]; then
      lk_log "::warning::Deploy lock: $what — this is a re-run of it, deploying the same changes again."
    elif [ "${LK_SCOPE:-}" = selective ]; then
      echo "::error::Deploy lock: $what. A selective deploy uploads only its own commits and would leave the gaps of that run on the server. Run a full deploy once: workflow_dispatch without 'commits' (or a push with DEPLOY_LAST_COMMITS=false)." >&2
      return 3
    else
      lk_log "::warning::Deploy lock: $what — this full deploy overwrites it."
    fi
  fi

  lk__state_text running | lkt_write "state/$key"
}

lk_mark_state() {
  local want="$1" only_if="${2:-}" key rec
  case "${LK_RUN_NUMBER:-}" in ''|*[!0-9]*) return 0 ;; esac
  [ -n "$LK_TOKEN" ] || return 0
  key="$(lk_state_key)"
  rec="$(lkt_read "state/$key" || true)"
  [ "$(lk_field token "$rec" || true)" = "$LK_TOKEN" ] || return 0
  if [ -n "$only_if" ] && [ "$(lk_field status "$rec" || true)" != "$only_if" ]; then return 0; fi
  lk__state_text "$want" | lkt_write "state/$key"
}

lk_stop_heartbeat() {
  local pid="${LK_HB_PID:-}"
  [ -n "$pid" ] || return 0
  kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
}
