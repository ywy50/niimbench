#!/bin/sh
# Run one command against a throwaway niimbench server, then stop the server.
#
#   tools/with-server.sh COMMAND [ARGS...]
#
# This is how a check or an agent gets a server. Nothing else starts one in
# the background: a server started with `&` outlives whoever started it.
#
# The command gets, in its environment:
#
#   NIIMBENCH_URL   the startup URL, token included
#   NIIMBENCH_PID   the server's pid
#   NIIMBENCH_DIR   the server's working directory, deleted afterwards
#
# The server runs in a directory of its own, because the single-server lock is
# per directory: it neither blocks nor is blocked by one you are using. It boots
# from tools/harness.patch.yml, which has no printer plugins, so whatever is
# plugged in or paired cannot change what the command sees, and nothing it does
# reaches a printer.
#
# It cannot be left running. It is started with `--parent`, so the kernel kills
# it when this script exits, even when this script is killed with SIGKILL and
# never runs the cleanup below. `make stray-test` holds that in place.
set -eu

[ $# -gt 0 ] || { echo "usage: tools/with-server.sh COMMAND [ARGS...]" >&2; exit 2; }

root=$(cd "$(dirname "$0")/.." && pwd)
binary="$root/zig-out/bin/niimbench"
[ -x "$binary" ] || { echo "with-server: $binary is missing; run make build first" >&2; exit 1; }

dir=$(mktemp -d)
server_pid=""
cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cp "$root/tools/harness.patch.yml" "$dir/cordis.patch.yml"
# `exec`, so `$!` is the server and not a shell wrapped round it. Killing the
# wrapper instead orphaned the server, which is how sixty of them piled up.
# `$$` is this script, which `exec` makes the server's parent.
( cd "$dir" && exec "$binary" --no-open --parent $$ > "$dir/server.log" 2>&1 ) &
server_pid=$!

url=""
i=0
while [ $i -lt 80 ]; do
  url=$(sed -n 's|^\(http://127\.0\.0\.1:[0-9]*/?token=[0-9a-f]*\).*|\1|p' "$dir/server.log" | head -1)
  [ -n "$url" ] && break
  if ! kill -0 "$server_pid" 2>/dev/null; then break; fi
  i=$((i + 1))
  sleep 0.25
done
if [ -z "$url" ]; then
  echo "with-server: the server never printed a URL:" >&2
  sed 's/^/  /' "$dir/server.log" >&2
  exit 1
fi

# A URL on stdout is a promise, not a fact.
if command -v curl >/dev/null 2>&1; then
  i=0
  while [ $i -lt 80 ] && ! curl -fsS "$url" >/dev/null 2>&1; do
    i=$((i + 1))
    sleep 0.25
  done
fi

NIIMBENCH_URL=$url
NIIMBENCH_PID=$server_pid
NIIMBENCH_DIR=$dir
export NIIMBENCH_URL NIIMBENCH_PID NIIMBENCH_DIR

status=0
"$@" || status=$?
exit "$status"
