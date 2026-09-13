#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MODE="${1:---check}"

render() {
  local file="$1" indent="" path="" inside=0 line
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$inside" -eq 1 ]; then
      case "$line" in
        *'# <<< '*)
          inside=0
          printf '%s\n' "$line"
          ;;
      esac
      continue
    fi

    printf '%s\n' "$line"

    case "$line" in
      *'# >>> '*)
        indent="${line%%#*}"
        path="${line#*'# >>> '}"
        path="${path%% *}"
        if [ ! -f "$ROOT/$path" ]; then
          echo "::error::snippet '$path' referenced by $file does not exist" >&2
          exit 1
        fi
        inside=1
        while IFS= read -r body || [ -n "$body" ]; do
          if [ -z "$body" ]; then printf '\n'; else printf '%s%s\n' "$indent" "$body"; fi
        done < "$ROOT/$path"
        ;;
    esac
  done < "$file"

  if [ "$inside" -eq 1 ]; then
    echo "::error::$file: маркер '# >>> $path' не закрыт '# <<< $path'" >&2
    exit 1
  fi
}

status=0
found=0
for file in "$ROOT"/.github/workflows/*.yml; do
  grep -q '# >>> ' "$file" || continue
  found=$((found + 1))
  rel="${file#"$ROOT"/}"
  tmp="$(mktemp)"
  render "$file" > "$tmp"

  if cmp -s "$file" "$tmp"; then
    [ "$MODE" = "--check" ] && echo "  ok   $rel"
    rm -f "$tmp"
    continue
  fi

  if [ "$MODE" = "--write" ]; then
    cat "$tmp" > "$file"
    echo "  обновлён $rel"
  else
    echo "  FAIL $rel — встроенная копия разошлась с .github/snippets"
    diff -u "$file" "$tmp" | sed -n '3,40p' | sed 's/^/       /' || true
    status=1
  fi
  rm -f "$tmp"
done

if [ "$found" -eq 0 ]; then
  echo "  FAIL ни один workflow не встраивает сниппеты — маркеры '# >>> ' потерялись"
  status=1
fi

exit "$status"
