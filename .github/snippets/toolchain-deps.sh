# Some mise plugins build a tool from source and expect the system libraries
# to be present. The built binary links against them dynamically, so they are
# installed on every run, including a toolchain cache hit.
__pkgs=()
if [ "${RUNNER_OS:-}" = "Linux" ] && command -v apt-get >/dev/null 2>&1; then
  for __t in ${TOOLS:-}; do
    __n="${__t%@*}"
    case "$__n" in
      php|*/php|*-php)
        __pkgs+=(build-essential autoconf bison re2c pkg-config
          libxml2-dev libssl-dev libicu-dev libzip-dev libonig-dev libcurl4-openssl-dev
          libpng-dev libjpeg-dev libfreetype-dev libwebp-dev libgmp-dev libsodium-dev
          libreadline-dev libbz2-dev libsqlite3-dev libpq-dev libgd-dev)
        ;;
    esac
  done
fi

# Arrays are expanded only when non-empty: macOS runners ship bash 3.2, where
# "${a[@]}" of an empty array trips set -u.
if [ "${#__pkgs[@]}" -gt 0 ]; then
  __missing=()
  for __p in "${__pkgs[@]}"; do
    if [ "${#__missing[@]}" -gt 0 ]; then
      case " ${__missing[*]} " in *" $__p "*) continue ;; esac
    fi
    if ! dpkg-query -W -f='${Status}' "$__p" 2>/dev/null | grep -q 'install ok installed'; then
      __missing+=("$__p")
    fi
  done

  if [ "${#__missing[@]}" -eq 0 ]; then
    echo "Toolchain build dependencies already present."
  else
    echo "Installing toolchain build dependencies: ${__missing[*]}"
    sudo apt-get update -q
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${__missing[@]}"
  fi
fi

unset __pkgs __missing __p __t __n
