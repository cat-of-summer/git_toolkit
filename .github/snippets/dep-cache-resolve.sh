# Resolves the dependency cache from CACHE_PATHS and CACHE_KEY_FILES into DEP_PATHS
# (one path per line), DEP_KEY and DEP_KEY_PREFIX. Empty CACHE_PATHS leaves all three
# empty, which switches the cache steps off.
# Inputs: CACHE_PATHS, CACHE_KEY_FILES.
DEP_PATHS=""
DEP_KEY=""
DEP_KEY_PREFIX=""

__split() {
  printf '%s' "${1:-}" \
    | tr ',' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -v '^$' || true
}

__sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi
}

if [ -z "${CACHE_PATHS:-}" ]; then
  echo "CACHE_PATHS is not set — skipping the dependency cache."
else
  DEP_PATHS="$(__split "$CACHE_PATHS")"
  if [ -z "$DEP_PATHS" ]; then
    echo "::error::CACHE_PATHS='$CACHE_PATHS' does not contain a single path." >&2
    exit 1
  fi

  __patterns="$(__split "${CACHE_KEY_FILES:-}")"
  if [ -z "$__patterns" ]; then
    echo "::error::CACHE_PATHS is set, but CACHE_KEY_FILES is empty. Without key files the cache would be saved once and never refreshed — list the lock files the dependencies come from, e.g. 'package-lock.json'." >&2
    exit 1
  fi

  shopt -s globstar nullglob dotglob

  __files=()
  while IFS= read -r __pattern; do
    [ -z "$__pattern" ] && continue
    eval "__matches=( $__pattern )"
    for __f in "${__matches[@]}"; do
      [ -f "$__f" ] && __files+=("$__f")
    done
  done <<< "$__patterns"

  shopt -u globstar nullglob dotglob

  if [ ${#__files[@]} -eq 0 ]; then
    echo "::error::No files matched CACHE_KEY_FILES: $CACHE_KEY_FILES" >&2
    exit 1
  fi

  __hash=$(
    printf '%s\n' "${__files[@]}" | LC_ALL=C sort -u | while IFS= read -r __f; do
      printf '%s  %s\n' "$(__sha < "$__f" | cut -d' ' -f1)" "$__f"
    done | __sha | cut -c1-64
  )

  DEP_KEY_PREFIX="deps-${RUNNER_OS}-${RUNNER_ARCH}-"
  DEP_KEY="${DEP_KEY_PREFIX}${__hash}"

  echo "Cache paths:"
  printf '%s\n' "$DEP_PATHS" | sed 's/^/  /'
  echo "Key files:"
  printf '%s\n' "${__files[@]}" | LC_ALL=C sort -u | sed 's/^/  /'
  echo "Key: $DEP_KEY"
fi

unset -f __split __sha
unset __patterns __pattern __files __matches __f __hash
