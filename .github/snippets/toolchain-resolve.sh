# Parses TOOLCHAIN ("node:24,php@8.4,ubi:owner/repo@1.2.3") into TOOLS, mise specs
# "name@version" separated by spaces, and resolves MISE_DIR, where mise keeps the
# installs, and TOOLCHAIN_KEY, the cache key of that directory.
# Inputs: TOOLCHAIN, MISE_FILES_HASH (hashFiles of .mise.toml and .tool-versions).
__backends="ubi,aqua,asdf,cargo,go,npm,pipx,gem,dotnet,spm,vfox,http"
TOOLS=""
while IFS= read -r __item; do
  __item="$(printf '%s' "$__item" | tr -d '[:space:]')"
  if [ -z "$__item" ]; then continue; fi
  __prefix="${__item%%:*}"
  __rest="${__item#*:}"
  if [ "$__prefix" != "$__item" ] && [[ ",$__backends," == *",$__prefix,"* ]] && [[ "$__rest" == */* ]]; then
    __after="${__rest##*/}"
    if [[ "$__after" == *@* ]]; then
      __ver="${__after##*@}"; __name="$__prefix:${__rest%@*}"
    else
      __ver="latest"; __name="$__prefix:$__rest"
    fi
  elif [[ "$__item" == *@* ]]; then
    __name="${__item%@*}"; __ver="${__item##*@}"
  elif [ "$__prefix" != "$__item" ]; then
    __name="$__prefix"; __ver="$__rest"
  else
    __name="$__item"; __ver="latest"
  fi
  TOOLS="$TOOLS $__name@$__ver"
done <<< "$(printf '%s' "${TOOLCHAIN:-}" | tr ',' '\n')"
TOOLS="${TOOLS# }"

if [ -z "$TOOLS" ]; then
  echo "TOOLCHAIN is not set — skipping tool installation."
else
  echo "Tools: $TOOLS"
fi

if [ -n "${MISE_DATA_DIR:-}" ]; then
  MISE_DIR="$MISE_DATA_DIR"
elif [ -n "${XDG_DATA_HOME:-}" ]; then
  MISE_DIR="$XDG_DATA_HOME/mise"
elif [ "$RUNNER_OS" = "Windows" ]; then
  MISE_DIR="$LOCALAPPDATA/mise"
else
  MISE_DIR="$HOME/.local/share/mise"
fi
MISE_DIR="$(printf '%s' "$MISE_DIR" | tr '\\' '/')"

# The key is shared by every job that installs the toolchain; keep its format stable,
# or caches already saved on the default branch stop matching.
TOOLCHAIN_KEY="mise-${RUNNER_OS}-${RUNNER_ARCH}-${MISE_FILES_HASH:-}-${TOOLS}"

unset __backends __item __prefix __rest __after __ver __name
