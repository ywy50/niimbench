#!/bin/sh
# Build one Linux release: the static binary, its tarball, and the .deb and
# .rpm packages, each with a .sha256.
#
#   tools/linux-dist.sh TARGET [OUT]
#
# TARGET is x86_64-linux or aarch64-linux, and OUT defaults to zig-out/dist.
# It writes niimbench-TARGET.tar.gz, niimbench-TARGET.deb and
# niimbench-TARGET.rpm there, names without the version, so
# releases/latest/download/<name> is always the newest.
#
# The packages are made by nfpm (https://nfpm.goreleaser.com) from the same
# files the tarball holds; without nfpm on PATH only the tarball is built, and
# the script says so. The release workflow and CI both run this script, so
# what CI checks is what a release ships.
set -eu

target=${1:-}
root=$(cd "$(dirname "$0")/.." && pwd)
out=${2:-$root/zig-out/dist}
case "$out" in /*) ;; *) out=$(pwd)/$out ;; esac
case "$target" in
  x86_64-linux) pkgarch=amd64 ;;
  aarch64-linux) pkgarch=arm64 ;;
  *) echo "usage: tools/linux-dist.sh x86_64-linux|aarch64-linux [OUT]" >&2; exit 2 ;;
esac
version=$(sed -n 's/^ *\.version = "\([^"]*\)",.*/\1/p' "$root/build.zig.zon" | head -1)
[ -n "$version" ] || { echo "linux-dist: no .version in build.zig.zon" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$root"

zig build -Doptimize=ReleaseSafe -Dtarget="$target" --prefix "$work/build"
bin="$work/build/bin/niimbench"
# niimbench links no libc, so the binary runs on any distribution. A dynamic
# one would not, and fails here instead of in someone's hands.
if file "$bin" | grep -q dynamically; then
  echo "linux-dist: $bin is dynamically linked; releases are static" >&2
  exit 1
fi
# The binary proves its version wherever it can run, which is on a machine of
# its own architecture, as each release runner is.
if [ "$(uname -m)-linux" = "$target" ]; then
  reported=$("$bin" --version | awk '{print $2}')
  [ "$reported" = "$version" ] || { echo "linux-dist: the binary reports $reported, build.zig.zon says $version" >&2; exit 1; }
fi

name="niimbench-$target"
stage="$out/$name"
rm -rf "$stage"
mkdir -p "$stage/licenses/fonts" "$stage/share/applications" \
  "$stage/share/icons/hicolor/scalable/apps" "$stage/share/icons/hicolor/512x512/apps"
cp "$bin" LICENSE README.md CHANGELOG.md "$stage/"
# The fonts compiled into the binary travel with their licences, which their
# terms require.
cp src/fonts/README.md src/fonts/*LICENSE* src/fonts/*OFL* "$stage/licenses/fonts/"
# The menu entry and its icon, for a package to install or a person to copy
# into ~/.local/share.
cp packaging/linux/niimbench.desktop "$stage/share/applications/"
cp docs/assets/icon.svg "$stage/share/icons/hicolor/scalable/apps/niimbench.svg"
cp docs/assets/icon-512.png "$stage/share/icons/hicolor/512x512/apps/niimbench.png"

tar -C "$out" --owner=0 --group=0 --numeric-owner -czf "$out/$name.tar.gz" "$name"
(cd "$out" && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256")

if command -v nfpm >/dev/null 2>&1; then
  for packager in deb rpm; do
    (cd "$stage" && NIIMBENCH_VERSION=$version NIIMBENCH_ARCH=$pkgarch \
      nfpm package --config "$root/packaging/linux/nfpm.yaml" --packager "$packager" --target "$out/$name.$packager")
    (cd "$out" && sha256sum "$name.$packager" > "$name.$packager.sha256")
  done
else
  echo "linux-dist: no nfpm on PATH, so no .deb or .rpm; the tarball is built" >&2
fi
(cd "$out" && cat ./*.sha256)
