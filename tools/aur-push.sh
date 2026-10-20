#!/bin/sh
# Publish the PKGBUILD and .SRCINFO that tools/aur.sh wrote as the AUR package
# niimbench-bin.
#
#   AUR_SSH_PRIVATE_KEY=... tools/aur-push.sh DIR
#
# AUR_SSH_PRIVATE_KEY is the private half of an SSH key registered with an AUR
# account, which the release workflow reads from the repository secret of that
# name. Without it the script says so and exits 0, so a release goes ahead
# whether or not the AUR is set up; docs/cookbook/releasing.md says how to set
# it up, and how to publish the files by hand meanwhile. The first push
# creates the package on the AUR, owned by that account.
set -eu

dir=${1:?usage: tools/aur-push.sh DIR}
if [ -z "${AUR_SSH_PRIVATE_KEY:-}" ]; then
  echo "aur-push: no AUR_SSH_PRIVATE_KEY, so niimbench-bin is not published; the PKGBUILD and .SRCINFO are in $dir"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
umask 077
printf '%s\n' "$AUR_SSH_PRIVATE_KEY" > "$work/key"
# The AUR's host key, pinned. Its fingerprint, SHA256:RFzBCUItH9LZS0cKB5UE6ceAYhBD5C8GeOBip8Z11+4,
# is the one https://aur.archlinux.org lists.
echo 'aur.archlinux.org ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEuBKrPzbawxA/k2g6NcyV5jmqwJ2s+zpgZGZ7tpLIcN' > "$work/known_hosts"
GIT_SSH_COMMAND="ssh -i $work/key -o IdentitiesOnly=yes -o UserKnownHostsFile=$work/known_hosts -o StrictHostKeyChecking=yes"
export GIT_SSH_COMMAND

git clone -q ssh://aur@aur.archlinux.org/niimbench-bin.git "$work/repo"
cp "$dir/PKGBUILD" "$dir/.SRCINFO" "$work/repo/"
cd "$work/repo"
git add PKGBUILD .SRCINFO
if git diff --cached --quiet; then
  echo "aur-push: the AUR already has this niimbench-bin"
  exit 0
fi
version=$(sed -n 's/^pkgver=//p' PKGBUILD)
git -c user.name=ywy50 -c user.email=84476743+ywy50@users.noreply.github.com commit -q -m "niimbench-bin $version"
git push -q origin HEAD:master
echo "aur-push: published niimbench-bin $version"
