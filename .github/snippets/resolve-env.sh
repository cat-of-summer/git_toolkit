__slug() { printf '%s' "${1:-}" | tr -d '\r' | tr '/' '-'; }
__trim() { printf '%s' "${1:-}" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }
__fail() { echo "::error::$1" >&2; exit 1; }

MULTIPLE_PACKAGES="$(__trim "${MULTIPLE_PACKAGES:-}" | tr '[:upper:]' '[:lower:]')"
__input_env="$(__trim "${INPUT_ENVIRONMENT:-}")"

if [ -n "$__input_env" ]; then
  REF_BRANCH="$(__slug "$__input_env")"
  echo "Environment overridden by the workflow_dispatch input."

elif [ -z "${REF_BRANCH:-}" ]; then
  __found="$(git branch -r --contains "$REF_COMMIT" 2>/dev/null | grep -v HEAD | head -1 | sed 's#.*origin/##' | tr -d '[:space:]' || true)"
  if [ -z "$__found" ]; then
    __fail "Cannot tell which branch tag '$REF_NAME' was cut from: commit $REF_COMMIT is not on any remote branch. Checkout with fetch-depth: 0 is required."
  fi
  REF_BRANCH="$(__slug "$__found")"

elif [ "$REF_TYPE" = "tag" ] && [ -n "${REF_TAG_BRANCH:-}" ]; then
  if ! git ls-remote --exit-code --heads origin "$REF_TAG_BRANCH" >/dev/null 2>&1; then
    __fail "Branch '$REF_TAG_BRANCH' from tag '$REF_NAME' not found."
  fi
fi

__suffix=""
if [ "$MULTIPLE_PACKAGES" = "true" ]; then __suffix="-${REF_BRANCH}"; fi

if [ -n "$__suffix" ]; then
  echo "Environment resolved to: '$REF_BRANCH' (package suffix '$__suffix')"
else
  echo "Environment resolved to: '$REF_BRANCH'"
fi

{
  echo "ref_branch=$REF_BRANCH"
  echo "environment=$REF_BRANCH"
  echo "pkg_suffix=$__suffix"
} >> "$GITHUB_OUTPUT"

echo "REF_BRANCH=$REF_BRANCH" >> "$GITHUB_ENV"

unset -f __slug __trim __fail
unset __input_env __found __suffix
