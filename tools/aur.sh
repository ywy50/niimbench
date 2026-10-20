#!/bin/sh
# Write the AUR package niimbench-bin for one release: its PKGBUILD and
# .SRCINFO, from packaging/aur/PKGBUILD.in.
#
#   tools/aur.sh VERSION OUT [BASE]
#
# BASE is the folder or URL that holds the release's Linux tarballs and their
# .sha256 files. It defaults to the GitHub release vVERSION; a check passes a
# file:// folder that tools/linux-dist.sh wrote instead. The checksums are read
# from those .sha256 files, so the PKGBUILD pins exactly what was published.
#
# The .SRCINFO is makepkg's own: from makepkg here on an Arch machine, or else
# from makepkg in an archlinux container, which needs docker.
set -eu

version=${1:-}
out=${2:-}
base=${3:-}
[ -n "$version" ] && [ -n "$out" ] || { echo "usage: tools/aur.sh VERSION OUT [BASE]" >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
case "$out" in /*) ;; *) out=$(pwd)/$out ;; esac

if [ -z "$base" ]; then
  fetch="https://github.com/ywy50/niimbench/releases/download/v$version"
  # In the PKGBUILD the URL is written with its own variables, as a person
  # writing one by hand would.
  source_base='$url/releases/download/v$pkgver'
else
  fetch=$base
  source_base=$base
fi

checksum() {
  sum=$(curl -fsSL "$fetch/niimbench-$1-linux.tar.gz.sha256" | awk '{print $1}')
  case "$sum" in
    *[!0-9a-f]* | "") echo "aur: no sha256 for niimbench-$1-linux.tar.gz at $fetch" >&2; exit 1 ;;
  esac
  [ ${#sum} -eq 64 ] || { echo "aur: $1's sha256 at $fetch is not 64 hex digits" >&2; exit 1; }
  printf '%s' "$sum"
}
x86_64=$(checksum x86_64)
aarch64=$(checksum aarch64)

mkdir -p "$out"
sed -e "s|@VERSION@|$version|g" -e "s|@BASE@|$source_base|g" \
  -e "s|@SHA256_X86_64@|$x86_64|" -e "s|@SHA256_AARCH64@|$aarch64|" \
  "$root/packaging/aur/PKGBUILD.in" > "$out/PKGBUILD"
if grep -q '@[A-Z0-9_]*@' "$out/PKGBUILD"; then
  echo "aur: a placeholder is left in $out/PKGBUILD" >&2
  exit 1
fi

# makepkg will not run as root, so the container builds as a user of its own.
if command -v makepkg >/dev/null 2>&1 && [ "$(id -u)" != 0 ]; then
  (cd "$out" && makepkg --printsrcinfo > .SRCINFO)
else
  docker run --rm -v "$out/PKGBUILD:/in/PKGBUILD:ro" archlinux:base sh -euc '
    useradd -m builder
    cp /in/PKGBUILD /home/builder/
    cd /home/builder
    su builder -c "makepkg --printsrcinfo"
  ' > "$out/.SRCINFO"
fi
grep -q "pkgver = $version" "$out/.SRCINFO" || { echo "aur: $out/.SRCINFO does not say pkgver $version" >&2; exit 1; }
echo "aur: niimbench-bin $version in $out"
