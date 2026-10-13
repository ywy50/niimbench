#!/bin/sh
# Read back the trace from one boot of the page and insist it is complete.
#
#   tools/trace-test.sh <browser>
#
# This is the harness for finding out what the editor did. The server is started
# in its own temporary directory (the single-server lock is per directory, so
# this neither blocks nor is blocked by a server already running here), the page
# is loaded once in a headless browser, and `tools/trace-test.js` reads the
# trace both sides wrote and checks it against the protocol.
#
# When something is wrong, run this first: it prints the whole trace, so the
# answer is in front of you instead of being inferred from a screenshot.
set -eu

browser="${1:?usage: trace-test.sh <browser>}"
dir=$(mktemp -d)
server_log="$dir/server.log"

cleanup() {
  if [ -n "${server_pid:-}" ]; then kill "$server_pid" 2>/dev/null || true; fi
  rm -rf "$dir"
}
trap cleanup EXIT INT TERM

binary="$(pwd)/zig-out/bin/niimbench"
[ -x "$binary" ] || { echo "trace-test: $binary is missing; run make build first"; exit 1; }

( cd "$dir" && "$binary" --no-open > "$server_log" 2>&1 ) &
server_pid=$!

url=""
i=0
while [ $i -lt 80 ]; do
  url=$(sed -n 's|^\(http://127\.0\.0\.1:[0-9]*/?token=[0-9a-f]*\).*|\1|p' "$server_log" | head -1)
  [ -n "$url" ] && break
  i=$((i + 1))
  sleep 0.25
done
if [ -z "$url" ]; then
  echo "trace-test: the server never printed a URL:"
  sed 's/^/  /' "$server_log"
  exit 1
fi

i=0
while [ $i -lt 80 ]; do
  if command -v curl >/dev/null 2>&1; then
    curl -fsS "$url" >/dev/null 2>&1 && break
  else
    break
  fi
  i=$((i + 1))
  sleep 0.25
done

status=0
node "$(dirname "$0")/trace-test.js" --chrome "$browser" --url "$url" --timeout "${TRACE_BUDGET_MS:-30000}" || status=$?
exit "$status"
