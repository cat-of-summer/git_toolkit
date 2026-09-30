# Writes vars and secrets of the job into a sourceable file and exports CTX_ENV with
# its path, so user commands see them as ordinary environment variables.
# Inputs: VARS_JSON, EXTRA_SECRETS (SECRETS_JSON, masked), ALL_SECRETS.
tmp="$RUNNER_TEMP"
if command -v cygpath >/dev/null 2>&1; then tmp="$(cygpath -u "$RUNNER_TEMP")"; fi
CTX="$tmp/ctx_env.sh"
: > "$CTX"
chmod 600 "$CTX"

DENY='^(PATH|HOME|IFS|PWD|OLDPWD|SHELL|SHELLOPTS|PS[0-9]|BASH.*|LD_.*|GITHUB_.*|RUNNER_.*|ACTIONS_.*|TMP_KEY|GT_SSH|GT_AUTH_MODE|CTX|CTX_ENV|GIT_ASKPASS|GIT_CONFIG.*|GIT_TERMINAL_PROMPT|GIT_AUTH_TOKEN.*|VARS_JSON|ALL_SECRETS|EXTRA_SECRETS|github_token|REF_TYPE|REF_NAME|REF_NAME_NORM|REF_BRANCH|REF_COMMIT|TARGET_COMMIT|PUBLISHED_IMAGE|PUBLISHED_IMAGE_TAG|WARM_CACHE)$'

emit() {
  local json="$1" mask="$2" label="$3"
  local names="" k b64 v

  if [ -z "$json" ] || [ "$json" = "null" ] || [ "$json" = "{}" ]; then
    echo "$label: <none>"
    return 0
  fi
  if ! printf '%s' "$json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "::error::$label is not a JSON object. Expected {\"NAME\":\"value\", ...}." >&2
    exit 1
  fi

  while IFS=$'\t' read -r k b64; do
    [ -z "$k" ] && continue
    case "$k" in [A-Za-z_][A-Za-z0-9_]*) ;; *) continue ;; esac
    if printf '%s' "$k" | grep -qE "$DENY"; then continue; fi
    v="$(printf '%s' "$b64" | base64 -d)"
    if [ "$mask" = "mask" ] && [ -n "$v" ]; then
      printf '%s\n' "$v" | while IFS= read -r line; do
        [ -n "$line" ] && printf '::add-mask::%s\n' "$line"
      done
    fi
    printf 'export %s=%q\n' "$k" "$v" >> "$CTX"
    names="$names $k"
  done < <(printf '%s' "$json" \
    | jq -r 'to_entries[] | .key + "\t" + (.value | tostring | @base64)' \
    | tr -d '\r')

  echo "$label:${names:- <none>}"
}

emit "${VARS_JSON:-}"     nomask "vars"
emit "${EXTRA_SECRETS:-}" mask   "SECRETS_JSON"
emit "${ALL_SECRETS:-}"   nomask "secrets"

echo "CTX_ENV=$CTX" >> "$GITHUB_ENV"

unset -f emit
unset tmp CTX DENY
