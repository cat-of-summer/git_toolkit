TMP_KEY=$(mktemp)
printf '%s\n' "$DEPLOY_KEY" > "$TMP_KEY"
chmod 600 "$TMP_KEY"
echo "TMP_KEY=$TMP_KEY" >> "$GITHUB_ENV"

GT_SSH="$RUNNER_TEMP/gt-ssh"
GT_AUTH_MODE=""
SSH_COMMON=(-o StrictHostKeyChecking=no -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=3)

IS_PEM=0
case "$(head -n 1 "$TMP_KEY")" in
  -----BEGIN*) IS_PEM=1 ;;
esac

if [ "$IS_PEM" = 0 ]; then
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "::error::DEPLOY_KEY is not a PEM private key, so it is used as a password, but sshpass is not installed (step 'Install system packages' should have done it)." >&2
    exit 1
  fi
  echo "SSH auth: probing password..."
  if sshpass -f "$TMP_KEY" ssh \
       -o PreferredAuthentications=password -o PubkeyAuthentication=no \
       -o NumberOfPasswordPrompts=1 "${SSH_COMMON[@]}" \
       -p "$DEPLOY_PORT" "$DEPLOY_USER@$DEPLOY_HOST" true \
       2> "$RUNNER_TEMP/ssh_probe_password.log"; then
    GT_AUTH_MODE=password
  fi
fi

if [ -z "$GT_AUTH_MODE" ]; then
  echo "SSH auth: probing private key..."
  if ssh -i "$TMP_KEY" \
       -o PreferredAuthentications=publickey -o IdentitiesOnly=yes -o BatchMode=yes \
       "${SSH_COMMON[@]}" \
       -p "$DEPLOY_PORT" "$DEPLOY_USER@$DEPLOY_HOST" true \
       2> "$RUNNER_TEMP/ssh_probe_key.log"; then
    GT_AUTH_MODE=key
  fi
fi

if [ -z "$GT_AUTH_MODE" ]; then
  echo "::error::Cannot authenticate to $DEPLOY_USER@$DEPLOY_HOST:$DEPLOY_PORT — DEPLOY_KEY was tried both as a password and as a private key."
  for f in "$RUNNER_TEMP/ssh_probe_password.log" "$RUNNER_TEMP/ssh_probe_key.log"; do
    if [ -s "$f" ]; then echo "=== $(basename "$f") ==="; cat "$f"; fi
  done
  exit 1
fi

if [ "$GT_AUTH_MODE" = password ]; then
  {
    echo '#!/usr/bin/env bash'
    printf 'exec sshpass -f %q ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 %s -p %q "$@"\n' \
      "$TMP_KEY" "${SSH_COMMON[*]}" "$DEPLOY_PORT"
  } > "$GT_SSH"
else
  {
    echo '#!/usr/bin/env bash'
    printf 'exec ssh -i %q -o PreferredAuthentications=publickey -o IdentitiesOnly=yes -o BatchMode=yes %s -p %q "$@"\n' \
      "$TMP_KEY" "${SSH_COMMON[*]}" "$DEPLOY_PORT"
  } > "$GT_SSH"
fi
chmod 700 "$GT_SSH"

echo "GT_SSH=$GT_SSH" >> "$GITHUB_ENV"
echo "GT_AUTH_MODE=$GT_AUTH_MODE" >> "$GITHUB_ENV"
echo "SSH auth: using $GT_AUTH_MODE"
