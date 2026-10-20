#!/bin/sh
# Build and install the AUR package that tools/aur.sh wrote, the way someone
# using the AUR does, in a clean archlinux container, and check it: namcap
# finds nothing wrong with the PKGBUILD or the package, the binary reports the
# version, the menu entry, icons and licences are installed, and a start from
# the menu entry's command serves from the per-user folder, quits and cleans up.
#
#   tools/aur-check.sh DIR [BASE]
#
# DIR holds the PKGBUILD. BASE is the file:// folder its sources point at, if
# they point at one; it is mounted at the same path inside the container. It
# needs docker, and installs nothing on this machine.
set -eu

dir=${1:?usage: tools/aur-check.sh DIR [BASE]}
base=${2:-}
case "$dir" in /*) ;; *) dir=$(pwd)/$dir ;; esac
version=$(sed -n 's/^pkgver=//p' "$dir/PKGBUILD")
mount_base=""
if [ -n "$base" ]; then
  path=${base#file://}
  mount_base="-v $path:$path:ro"
fi

# shellcheck disable=SC2086 # mount_base is empty or two words on purpose
docker run --rm -v "$dir/PKGBUILD:/in/PKGBUILD:ro" $mount_base -e VERSION="$version" archlinux:base sh -euc '
  # And what the package depends on, as makepkg -s would install it: the
  # builder below has no sudo.
  pacman -Syu --noconfirm --needed base-devel namcap curl hicolor-icon-theme >/dev/null 2>&1
  useradd -m builder
  install -o builder -m 644 /in/PKGBUILD /home/builder/PKGBUILD
  cd /home/builder
  # These findings are expected and nothing else is. A -bin package names each
  # architecture in its sources, which namcap would have be $CARCH. The binary
  # is the release build as published and attested, so it is not stripped, and
  # it is static with no libc, which RELRO and PIE are hardening for the
  # dynamic loader of: there is none.
  su builder -c "namcap PKGBUILD" | grep -v "Reference to x86_64 should be changed to" | tee /tmp/namcap-pkgbuild || true
  su builder -c "makepkg --noconfirm >/tmp/makepkg.log 2>&1" || { cat /tmp/makepkg.log; exit 1; }
  package=$(ls /home/builder/niimbench-bin-*.pkg.tar.zst)
  namcap "$package" | grep -v "is unstripped\|lacks FULL RELRO\|lacks PIE" | tee /tmp/namcap-package || true
  pacman -U --noconfirm "$package" >/dev/null
  test "$(niimbench --version)" = "niimbench $VERSION"
  grep -qx "Exec=niimbench --app" /usr/share/applications/niimbench.desktop
  test -f /usr/share/icons/hicolor/scalable/apps/niimbench.svg
  test -f /usr/share/licenses/niimbench-bin/LICENSE
  ls /usr/share/licenses/niimbench-bin/fonts | grep -q OFL
  useradd -m tester
  su tester -c "
    set -eu
    niimbench --app --no-open --parent \$\$ > /tmp/server.log 2>&1 &
    state=\$HOME/.local/state/niimbench
    i=0; while [ ! -s \$state/.niimbench.token ] && [ \$i -lt 50 ]; do i=\$((i+1)); sleep 0.1; done
    url=\$(cat \$state/.niimbench.token)
    curl -fsS \"\${url%%/?token=*}/api/health?token=\${url##*token=}\" >/dev/null
    curl -fsS -X POST \"\${url%%/?token=*}/api/quit?token=\${url##*token=}\" >/dev/null
    wait
    test ! -e \$state/.niimbench.token
  "
  if [ -s /tmp/namcap-pkgbuild ] || [ -s /tmp/namcap-package ]; then
    echo "namcap has findings, above" >&2
    exit 1
  fi
  echo "aur package ok: $(niimbench --version)"
'
