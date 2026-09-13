extract_step() {
  local file="$1" step_id="$2"
  awk -v want="$step_id" '
    { line = $0; sub(/^[ \t]+/, "", line) }
    !found && line == "id: " want { found = 1; next }
    found && !grab {
      if (line == "run: |" || line == "run: |-") { grab = 1; indent = -1 }
      next
    }
    grab {
      if ($0 ~ /^[[:space:]]*$/) { print ""; next }
      match($0, /^ */)
      if (indent < 0) indent = RLENGTH
      if (RLENGTH < indent) exit
      print substr($0, indent + 1)
    }
  ' "$file"
}
