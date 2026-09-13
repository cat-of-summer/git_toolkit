TESTS_RUN=0
TESTS_FAILED=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_OK=''; C_BAD=''; C_DIM=''; C_OFF=''
fi

pass() {
  TESTS_RUN=$((TESTS_RUN + 1))
  printf '  %sok%s   %s\n' "$C_OK" "$C_OFF" "$1"
}

fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf '  %sFAIL%s %s\n' "$C_BAD" "$C_OFF" "$1"
  shift
  for line in "$@"; do printf '       %s%s%s\n' "$C_DIM" "$line" "$C_OFF"; done
}

check_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$label"
  else
    fail "$label" "ожидалось: $expected" "получено:  $actual"
  fi
}

suite_result() {
  if [ "$TESTS_FAILED" -eq 0 ]; then
    printf '%s%s: %d проверок, все зелёные%s\n' "$C_OK" "$1" "$TESTS_RUN" "$C_OFF"
    return 0
  fi
  printf '%s%s: %d проверок, провалено %d%s\n' "$C_BAD" "$1" "$TESTS_RUN" "$TESTS_FAILED" "$C_OFF"
  return 1
}
