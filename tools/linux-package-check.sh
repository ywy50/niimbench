#!/bin/sh
# Install a .deb or .rpm the way a person does, inside a container, and check
# what it put on the system: the binary reports the version, the menu entry
# and its icons are where the desktop looks, and a start from the menu entry's
# command serves from the per-user folder, quits, and cleans up.
#
#   tools/linux-package-check.sh PACKAGE IMAGE
#
# PACKAGE is a niimbench .deb or .rpm, IMAGE a container image that installs
# that kind with apt or dnf, such as debian:stable-slim or fedora:42. It needs
# docker. Nothing is installed on this machine.
set -eu

package=$1
image=$2
case "$package" in /*) ;; *) package=$(pwd)/$package ;; esac
root=$(cd "$(dirname "$0")/.." && pwd)
version=$(sed -n 's/^ *\.version = "\([^"]*\)",.*/\1/p' "$root/build.zig.zon" | head -1)
case "$package" in
  *.deb) install='export DEBIAN_FRONTEND=noninteractive; apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends curl ca-certificates /pkg/niimbench.deb >/dev/null' ;;
  *.rpm) install='dnf install -y -q /pkg/niimbench.rpm curl util-linux >/dev/null' ;;
  *) echo "linux-package-check: $package is not a .deb or .rpm" >&2; exit 2 ;;
esac
ext=${package##*.}

docker run --rm -v "$package:/pkg/niimbench.$ext:ro" -e VERSION="$version" "$image" sh -euc "
$install
test \"\$(niimbench --version)\" = \"niimbench \$VERSION\"
test -f /usr/share/applications/niimbench.desktop
grep -qx 'Exec=niimbench --app' /usr/share/applications/niimbench.desktop
test -f /usr/share/icons/hicolor/scalable/apps/niimbench.svg
test -f /usr/share/icons/hicolor/512x512/apps/niimbench.png
test -f /usr/share/licenses/niimbench/LICENSE
ls /usr/share/licenses/niimbench/fonts | grep -q OFL
useradd -m tester
su tester -c '
  set -eu
  niimbench --app --no-open --parent \$\$ > /tmp/server.log 2>&1 &
  state=\$HOME/.local/state/niimbench
  i=0; while [ ! -s \$state/.niimbench.token ] && [ \$i -lt 50 ]; do i=\$((i+1)); sleep 0.1; done
  url=\$(cat \$state/.niimbench.token)
  curl -fsS \"\${url%%/?token=*}/api/health?token=\${url##*token=}\" >/dev/null
  curl -fsS -X POST \"\${url%%/?token=*}/api/quit?token=\${url##*token=}\" >/dev/null
  wait
  test ! -e \$state/.niimbench.token
'
echo \"package ok: \$(niimbench --version) on $image\"
"
