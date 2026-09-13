__lower() { printf '%s' "${1:-}" | tr -d '\r' | tr '[:upper:]' '[:lower:]'; }
__trim()  { printf '%s' "${1:-}" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }
__slug()  { printf '%s' "${1:-}" | tr -d '\r' | tr '/' '-'; }
__fail()  { echo "::error::$1" >&2; exit 1; }

MULTIPLE_PACKAGES="$(__lower "$(__trim "${MULTIPLE_PACKAGES:-}")")"

__event="${GITHUB_EVENT_NAME:-}"
__raw_type="$(__trim "${GITHUB_REF_TYPE:-}")"
__raw_name="$(__trim "${GITHUB_REF_NAME:-}")"

REF_TYPE=""
REF_NAME="$__raw_name"
REF_NAME_NORM=""
REF_BRANCH=""
REF_COMMIT="$(__trim "${GITHUB_SHA:-}")"
REF_TAG=""
REF_TAG_BRANCH=""

case "$__event" in
  pull_request|pull_request_target)
    REF_TYPE="pr"
    __pr="$(__trim "${PR_NUMBER:-}")"
    if [ -z "$__pr" ]; then __pr="${__raw_name%%/*}"; fi
    REF_NAME_NORM="pr-${__pr}"
    REF_BRANCH="$(__slug "${PR_BASE_REF:-}")"
    __head="$(__trim "${PR_HEAD_SHA:-}")"
    if [ -n "$__head" ]; then REF_COMMIT="$__head"; fi
    ;;

  *)
    if [ "$__raw_type" = "tag" ]; then
      REF_TYPE="tag"

      __prefix=""
      __vpart="$__raw_name"
      if [ "${__raw_name#*/}" != "$__raw_name" ]; then
        __prefix="${__raw_name%/*}"
        __vpart="${__raw_name##*/}"
      fi

      if ! printf '%s' "$__vpart" | grep -qE '^v[0-9]+(\.[0-9]+)*$'; then
        __fail "Tag '$__vpart' is not a v-version tag (expected v#, v#.#, v#.#.#)."
      fi
      if [ "$MULTIPLE_PACKAGES" = "true" ] && [ -z "$__prefix" ]; then
        __fail "MULTIPLE_PACKAGES=true: the tag must have the form '{branch}/vX.Y.Z' (got '$__raw_name')."
      fi
      if [ "$MULTIPLE_PACKAGES" != "true" ] && [ -n "$__prefix" ]; then
        __fail "MULTIPLE_PACKAGES is off: the tag must have the form 'vX.Y.Z' without a branch prefix (got '$__raw_name'). Set MULTIPLE_PACKAGES=true to use '{branch}/vX.Y.Z' tags."
      fi

      REF_TAG="$__vpart"
      REF_TAG_BRANCH="$__prefix"
      REF_BRANCH="$(__slug "$__prefix")"
      if [ -n "$__prefix" ]; then
        REF_NAME_NORM="${REF_BRANCH}-${__vpart#v}"
      else
        REF_NAME_NORM="${__vpart#v}"
      fi
    else
      REF_TYPE="branch"
      REF_BRANCH="$(__slug "$__raw_name")"
      REF_NAME_NORM="$REF_BRANCH"
    fi
    ;;
esac

if [ -z "$REF_NAME" ]; then __fail "Cannot determine what was pushed: GITHUB_REF_NAME is empty."; fi
if [ -z "$REF_COMMIT" ]; then __fail "Cannot determine the commit: GITHUB_SHA is empty."; fi

echo "ref_type=$REF_TYPE ref_name=$REF_NAME ref_name_norm=$REF_NAME_NORM ref_branch=${REF_BRANCH:-<by history>} ref_commit=$REF_COMMIT"

{
  echo "ref_type=$REF_TYPE"
  echo "ref_name=$REF_NAME"
  echo "ref_name_norm=$REF_NAME_NORM"
  echo "ref_branch=$REF_BRANCH"
  echo "ref_commit=$REF_COMMIT"
  echo "ref_tag=$REF_TAG"
  echo "ref_tag_branch=$REF_TAG_BRANCH"
} >> "$GITHUB_OUTPUT"

{
  echo "REF_TYPE=$REF_TYPE"
  echo "REF_NAME=$REF_NAME"
  echo "REF_NAME_NORM=$REF_NAME_NORM"
  echo "REF_BRANCH=$REF_BRANCH"
  echo "REF_COMMIT=$REF_COMMIT"
} >> "$GITHUB_ENV"

unset -f __lower __trim __slug __fail
unset __event __raw_type __raw_name __pr __head __prefix __vpart
