#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/assert.sh
. "$HERE/lib/assert.sh"

SNIPPET="$ROOT/.github/snippets/resolve-env.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

origin="$tmp/origin.git"
work="$tmp/work"
git init -q --bare "$origin"
git init -q "$work"
git -C "$work" remote add origin "$origin"
git -C "$work" config user.email t@t; git -C "$work" config user.name t
git -C "$work" commit -q --allow-empty -m first
git -C "$work" branch -M main
git -C "$work" push -q origin main
git -C "$work" checkout -q -b release/1.x
git -C "$work" commit -q --allow-empty -m second
git -C "$work" push -q origin release/1.x
git -C "$work" fetch -q origin

SHA_MAIN="$(git -C "$work" rev-parse origin/main)"
SHA_REL="$(git -C "$work" rev-parse origin/release/1.x)"
SHA_ORPHAN="$(git -C "$work" commit-tree -m orphan "$(git -C "$work" hash-object -t tree -w /dev/null)")"

run() {
  local out="$tmp/out" envf="$tmp/env"
  : > "$out"; : > "$envf"
  local log code
  log="$(cd "$work" && env \
    GITHUB_OUTPUT="$out" GITHUB_ENV="$envf" \
    bash -c 'set -euo pipefail; eval "$1"; . "$2"' _ "$1" "$SNIPPET" 2>&1)"
  code=$?
  LAST_LOG="$log"; LAST_OUT="$out"
  return $code
}

got() { grep -m1 "^$1=" "$LAST_OUT" | cut -d= -f2-; }

expect_ok() {
  local name="$1" setup="$2" key="$3" want="$4"
  if run "$setup"; then check_eq "$name" "$want" "$(got "$key")"
  else fail "$name" "шаг упал" "$LAST_LOG"; fi
}

expect_err() {
  local name="$1" setup="$2" want="$3"
  if run "$setup"; then fail "$name" "шаг обязан был упасть с «$want»" "$LAST_LOG"
  elif printf '%s' "$LAST_LOG" | grep -qF "$want"; then pass "$name"
  else fail "$name" "ожидалась ошибка со словами «$want»" "получено: $LAST_LOG"; fi
}

base="export REF_TYPE=branch REF_NAME=main REF_BRANCH=main REF_COMMIT=$SHA_MAIN REF_TAG_BRANCH= MULTIPLE_PACKAGES= INPUT_ENVIRONMENT="

expect_ok "ветка проходит насквозь" "$base" ref_branch main
expect_ok "environment совпадает с ref_branch" "$base" environment main
expect_ok "без multi суффикса пакета нет" "$base" pkg_suffix ""

expect_ok "multi даёт суффикс пакета" \
  "export REF_TYPE=branch REF_NAME=release/1.x REF_BRANCH=release-1.x REF_COMMIT=$SHA_REL REF_TAG_BRANCH= MULTIPLE_PACKAGES=true INPUT_ENVIRONMENT=" \
  pkg_suffix "-release-1.x"

expect_ok "ручной override окружения" \
  "$base INPUT_ENVIRONMENT=staging" ref_branch staging
expect_ok "override со слешем нормализуется" \
  "$base INPUT_ENVIRONMENT=release/2.x" ref_branch release-2.x

expect_ok "ветка плоского тега берётся из истории" \
  "export REF_TYPE=tag REF_NAME=v1.2.3 REF_BRANCH= REF_COMMIT=$SHA_REL REF_TAG_BRANCH= MULTIPLE_PACKAGES= INPUT_ENVIRONMENT=" \
  ref_branch release-1.x

expect_err "коммит вне веток — честная ошибка, а не пустое окружение" \
  "export REF_TYPE=tag REF_NAME=v9.9.9 REF_BRANCH= REF_COMMIT=$SHA_ORPHAN REF_TAG_BRANCH= MULTIPLE_PACKAGES= INPUT_ENVIRONMENT=" \
  "Cannot tell which branch"

expect_ok "ветка из префикса тега проверяется и принимается" \
  "export REF_TYPE=tag REF_NAME=release/1.x/v1.2.3 REF_BRANCH=release-1.x REF_COMMIT=$SHA_REL REF_TAG_BRANCH=release/1.x MULTIPLE_PACKAGES=true INPUT_ENVIRONMENT=" \
  ref_branch release-1.x

expect_err "опечатка в ветке тега ловится здесь, а не на деплое" \
  "export REF_TYPE=tag REF_NAME=nosuch/v1.2.3 REF_BRANCH=nosuch REF_COMMIT=$SHA_MAIN REF_TAG_BRANCH=nosuch MULTIPLE_PACKAGES=true INPUT_ENVIRONMENT=" \
  "not found"

suite_result "resolve-env"
