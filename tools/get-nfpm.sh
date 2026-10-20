#!/bin/sh
# Put nfpm, which tools/linux-dist.sh makes the .deb and .rpm with, in DIR.
#
#   tools/get-nfpm.sh DIR
#
# The version is pinned, and the download is checked against the checksum its
# release published, so a moved release or a changed file fails here instead of
# building packages. Linux on x86_64 or arm64.
set -eu

dir=${1:?usage: tools/get-nfpm.sh DIR}
version=2.47.0
case "$(uname -m)" in
  x86_64) arch=x86_64 sum=0660ca602b2d2d2ae4781a06c692b3eeb9d437ffea05b831d76e41f4a3188783 ;;
  aarch64 | arm64) arch=arm64 sum=1c0f5f2999b9a974bfb04fdb0cc3306096de530ac5dbb25d739cc5f5219c919c ;;
  *) echo "get-nfpm: no nfpm build for $(uname -m)" >&2; exit 1 ;;
esac

mkdir -p "$dir"
archive="$dir/nfpm_${version}_Linux_$arch.tar.gz"
curl -fsSLo "$archive" "https://github.com/goreleaser/nfpm/releases/download/v$version/nfpm_${version}_Linux_$arch.tar.gz"
echo "$sum  $archive" | sha256sum -c - >/dev/null
tar -xzf "$archive" -C "$dir" nfpm
rm -f "$archive"
"$dir/nfpm" --version | grep -q "$version" || { echo "get-nfpm: $dir/nfpm is not $version" >&2; exit 1; }
echo "nfpm $version in $dir"
