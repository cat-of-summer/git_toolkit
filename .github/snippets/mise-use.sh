# Installs TOOLS with mise and puts them on PATH for the following steps. A tool
# already in MISE_DIR (restored from the toolchain cache) is not installed again.
# Inputs: MISE, MISE_BIN_DIR, MISE_DIR, TOOLS.
export MISE_YES=1 MISE_PYTHON_COMPILE=false
# shellcheck disable=SC2086 # TOOLS is a list of specs
"$MISE" use --global $TOOLS
"$MISE" ls --installed

{
  "$MISE" bin-paths 2>/dev/null || true
  printf '%s\n%s\n' "$MISE_DIR/shims" "$MISE_BIN_DIR"
} | while IFS= read -r __p; do
  [ -z "$__p" ] && continue
  if command -v cygpath >/dev/null 2>&1; then __p="$(cygpath -w "$__p")"; fi
  printf '%s\n' "$__p" >> "$GITHUB_PATH"
done
