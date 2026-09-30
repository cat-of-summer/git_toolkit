# Downloads the mise binary into MISE_BIN_DIR and sets MISE to its path. The CDN serves
# the latest release; when it is down, the version comes from the VERSION endpoint or
# the GitHub API, and as a last resort a pinned release is used.
# Inputs: GH_TOKEN (optional, for the GitHub API).
case "$RUNNER_OS" in
  Linux)   __os=linux ;;
  macOS)   __os=macos ;;
  Windows) __os=windows ;;
  *) echo "::error::Unsupported OS RUNNER_OS='$RUNNER_OS'." >&2; exit 1 ;;
esac
case "$RUNNER_ARCH" in
  X64)   __arch=x64 ;;
  ARM64) __arch=arm64 ;;
  *) echo "::error::Unsupported architecture RUNNER_ARCH='$RUNNER_ARCH'." >&2; exit 1 ;;
esac
__ext=""
if [ "$__os" = "windows" ]; then __ext=".exe"; fi

__tmp="$RUNNER_TEMP"
if command -v cygpath >/dev/null 2>&1; then __tmp="$(cygpath -u "$RUNNER_TEMP")"; fi
MISE_BIN_DIR="$__tmp/mise-bin"
mkdir -p "$MISE_BIN_DIR"
MISE="$MISE_BIN_DIR/mise${__ext}"

MISE_FALLBACK_VERSION="v2026.7.12"

__try_download() {
  echo "  trying $1"
  curl -fsSL --retry 3 --retry-delay 2 -o "$MISE" "$1" 2>/dev/null || return 1
  chmod +x "$MISE" 2>/dev/null || true
  "$MISE" --version >/dev/null 2>&1 || return 1
  return 0
}

__release_url() {
  printf 'https://github.com/jdx/mise/releases/download/%s/mise-%s-%s-%s%s' "$1" "$1" "$__os" "$__arch" "$__ext"
}

__ok=false
echo "Resolving mise version…"
if __try_download "https://mise.jdx.dev/mise-latest-${__os}-${__arch}${__ext}"; then
  __ok=true
else
  echo "::warning::The mise CDN is unavailable — trying the VERSION endpoint and the GitHub API."
  __ver=$(curl -fsSL --retry 2 https://mise.jdx.dev/VERSION 2>/dev/null | tr -d '[:space:]' || true)
  if [ -n "$__ver" ]; then
    case "$__ver" in v*) ;; *) __ver="v$__ver" ;; esac
    if __try_download "$(__release_url "$__ver")"; then __ok=true; fi
  fi
  if [ "$__ok" != "true" ]; then
    __api="https://api.github.com/repos/jdx/mise/releases/latest"
    if [ -n "${GH_TOKEN:-}" ]; then
      __body=$(curl -fsSL -H "Authorization: Bearer $GH_TOKEN" "$__api" 2>/dev/null || true)
    else
      __body=$(curl -fsSL "$__api" 2>/dev/null || true)
    fi
    __ver=$(printf '%s' "$__body" | grep -m1 '"tag_name"' | sed 's/.*"tag_name"[^"]*"\([^"]*\)".*/\1/' || true)
    if [ -n "$__ver" ] && __try_download "$(__release_url "$__ver")"; then __ok=true; fi
  fi
  if [ "$__ok" != "true" ]; then
    echo "::warning::Neither the CDN nor the API responded — falling back to the pinned version $MISE_FALLBACK_VERSION."
    if __try_download "$(__release_url "$MISE_FALLBACK_VERSION")"; then __ok=true; fi
  fi
fi

if [ "$__ok" != "true" ]; then
  echo "::error::Failed to download mise. Check the runner's access to github.com and mise.jdx.dev." >&2
  exit 1
fi
echo "mise $("$MISE" --version)"

unset -f __try_download __release_url
unset __os __arch __ext __tmp __ok __ver __api __body
