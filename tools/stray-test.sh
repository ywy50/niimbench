#!/bin/sh
# No server outlives whoever started it.
#
#   tools/stray-test.sh
#
# Three ways a throwaway server ends, each checked by looking for the process
# afterwards:
#
#   1. the command under tools/with-server.sh finishes: the server is stopped;
#   2. tools/with-server.sh is killed with SIGKILL, so its cleanup never runs:
#      the kernel kills the server anyway, because of `--parent`;
#   3. `--parent` names a process that is not the parent: the server refuses
#      to start rather than run unwatched.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
binary="$here/../zig-out/bin/niimbench"
[ -x "$binary" ] || { echo "stray-test: $binary is missing; run make build first"; exit 1; }
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

failures=0
fail() { echo "  FAIL $1"; failures=$((failures + 1)); }

# Running and not a zombie. A killed server is a zombie until whoever inherited
# it reaps it, and `kill -0` still succeeds on one.
alive() {
  state=$(ps -o stat= -p "$1" 2>/dev/null || true)
  [ -n "$state" ] && [ "${state#Z}" = "$state" ]
}

# Up to five seconds for a pid to go.
gone() {
  i=0
  while alive "$1"; do
    i=$((i + 1))
    [ $i -lt 50 ] || return 1
    sleep 0.1
  done
}

# 1. A finished command stops its server.
"$here/with-server.sh" sh -c 'echo "$NIIMBENCH_PID" > "$1"' _ "$dir/finished"
server=$(cat "$dir/finished")
gone "$server" || fail "the server $server outlived the command run under it"

# 2. A launcher killed outright still takes its server with it.
"$here/with-server.sh" sh -c 'echo "$NIIMBENCH_PID $$" > "$1.tmp"; mv "$1.tmp" "$1"; exec sleep 600' _ "$dir/killed" &
launcher=$!
i=0
while [ ! -s "$dir/killed" ] && [ $i -lt 200 ]; do i=$((i + 1)); sleep 0.1; done
if [ ! -s "$dir/killed" ]; then
  kill -KILL "$launcher" 2>/dev/null || true
  fail "the launcher never started its command"
else
  read -r server sleeper < "$dir/killed"
  alive "$server" || fail "the server $server was not running before the launcher was killed"
  kill -KILL "$launcher"
  gone "$server" || fail "the server $server outlived a launcher killed with SIGKILL"
  # The command was the launcher's child, not the server's, so it is ours.
  kill "$sleeper" 2>/dev/null || true
fi

# 3. A wrong parent is refused, so a server cannot start believing it is watched.
if (cd "$dir" && "$binary" --no-open --parent 1 > "$dir/refused.log" 2>&1); then
  fail "a server whose --parent is not its parent started anyway"
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures stray check(s) failed"
  exit 1
fi
echo "stray ok"
