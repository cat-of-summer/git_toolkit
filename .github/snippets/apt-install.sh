read -r -a __pkgs <<< "${APT_PACKAGES:-}"

__missing=()
for __p in "${__pkgs[@]}"; do
  command -v "$__p" >/dev/null 2>&1 || __missing+=("$__p")
done

if [ "${#__missing[@]}" -eq 0 ]; then
  echo "System packages already present: ${__pkgs[*]:-<none>}"
else
  # Keep downloaded .deb files so the apt cache step has something to save.
  echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' | sudo tee /etc/apt/apt.conf.d/99keep-cache >/dev/null

  __debs=()
  for __p in "${__missing[@]}"; do
    for __d in /var/cache/apt/archives/"${__p}"_*.deb; do
      [ -f "$__d" ] && __debs+=("$__d")
    done
  done

  if [ "${CACHE_HIT:-}" = "true" ] && [ "${#__debs[@]}" -ge "${#__missing[@]}" ]; then
    echo "Installing from the apt cache: ${__missing[*]}"
    sudo dpkg -i "${__debs[@]}" || sudo apt-get install -f -y --no-install-recommends
  else
    echo "Installing: ${__missing[*]}"
    sudo apt-get update -q
    sudo apt-get install -y --no-install-recommends "${__missing[@]}"
  fi
fi

unset __pkgs __missing __p __debs __d
