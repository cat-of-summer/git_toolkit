#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/assert.sh
. "$HERE/lib/assert.sh"

WF="$ROOT/.github/workflows"

code_only() {
  awk '/# >>> /{skip=1} /# <<< /{skip=0; next} skip{next} /^[[:space:]]*#/{next} {print}' "$1"
}

banned() {
  local label="$1" pattern="$2" hits=""
  for f in "$WF"/*.yml; do
    local found
    found="$(code_only "$f" | grep -nE "$pattern" || true)"
    if [ -n "$found" ]; then
      hits="$hits${f##*/}: $(printf '%s' "$found" | head -3 | tr '\n' ' ')"$'\n'
    fi
  done
  if [ -z "$hits" ]; then pass "$label"; else fail "$label" "$hits"; fi
}

banned "github.ref_name нигде не читается напрямую"  'github\.ref_name'
banned "github.ref_type нигде не читается напрямую"  'github\.ref_type'
banned "github.sha нигде не читается напрямую"       'github\.sha'
banned 'GITHUB_REF#refs/heads больше не разбирается вручную' 'GITHUB_REF#refs/'
banned "выхода is_tag больше нет"                    'outputs\.is_tag'
banned "джобы resolve-branch больше нет"             'resolve-branch'
banned "REF_COMMIT не переиспользуется под коммит деплоя" 'REF_COMMIT=\$\(git'

for job_file in ci-cd.yml grabber.yml; do
  missing=""
  for v in REF_TYPE REF_NAME REF_NAME_NORM REF_BRANCH REF_COMMIT; do
    grep -qE "^      $v: \\$\{\{ needs\.resolve-ref\.outputs\." "$WF/$job_file" || missing="$missing $v"
  done
  if [ -z "$missing" ]; then
    pass "$job_file отдаёт контракт в env: джобы"
  else
    fail "$job_file отдаёт контракт в env: джобы" "не найдены:$missing"
  fi
done

missing=""
for v in REF_TYPE REF_NAME REF_NAME_NORM REF_BRANCH REF_COMMIT TARGET_COMMIT; do
  grep -qE "DENY='.*[|(]${v}[|)]" "$WF/ci-cd.yml" || missing="$missing $v"
done
if [ -z "$missing" ]; then
  pass "контракт закрыт от подмены через vars проекта"
else
  fail "контракт закрыт от подмены через vars проекта" "не попали в DENY шага Collect vars & secrets:$missing"
fi

suite_result "no-stale-refs"
