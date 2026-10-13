#!/bin/sh
# Report what niimbench did around one command.
#
# The trace plugin keeps a log in the running server (docs/subsystems/trace.md).
# This clears it, runs the command you give it, and prints only the lines that
# appeared, so the output is about that command and nothing else.
#
#   tools/trace.sh --port 8080 -- zig build run -- --no-open
#   tools/trace.sh --url http://127.0.0.1:8080 --token abc123 -- curl -s ...
#
# The command is run exactly as written, so quote it the way you would type it.
# It also gets `NIIMBENCH_URL` and `NIIMBENCH_TOKEN` in its environment, so a
# curl inside it does not have to be told the token twice.
#
# `--port` is a shortcut for `--url http://127.0.0.1:PORT`. Without `--token`
# the script runs the command first and reads the token the server prints, which
# is the step that otherwise makes a diagnostic tool go unused.
set -eu

usage() {
  cat <<'EOF'
usage: tools/trace.sh [--url URL] [--port PORT] [--token TOKEN] -- COMMAND [ARGS...]

  --url URL     where the server is listening (default http://127.0.0.1:8080)
  --port PORT   shorthand for --url http://127.0.0.1:PORT
  --token TOK   the session token; without it, one is read from COMMAND's output
  --            everything after this is the command to run

The log is cleared, COMMAND runs, and the lines it produced are printed.
EOF
}

url=""
port=""
token=""

while [ $# -gt 0 ]; do
  case "$1" in
    --url) url="$2"; shift 2 ;;
    --port) port="$2"; shift 2 ;;
    --token) token="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) usage >&2; echo "unexpected argument: $1" >&2; exit 2 ;;
  esac
done

if [ -n "$port" ]; then url="http://127.0.0.1:$port"; fi
if [ -z "$url" ]; then url="http://127.0.0.1:8080"; fi
if [ $# -eq 0 ]; then usage >&2; echo "no command given" >&2; exit 2; fi

command -v curl >/dev/null 2>&1 || { echo "curl is needed for tools/trace.sh" >&2; exit 1; }

# The log's URL. `extra` is `?clear=1` or empty.
trace_url() {
  if [ -n "$token" ]; then printf '%s/api/trace?token=%s%s' "$url" "$token" "$1";
  else printf '%s/api/trace%s' "$url" "$1"; fi
}

NIIMBENCH_URL="$url"
export NIIMBENCH_URL

if [ -z "$token" ]; then
  # No token yet: run the command, read the one the server printed, then show
  # the log it wrote. The token usually arrives on the startup URL.
  output=$("$@" 2>&1) || status=$?
  status=${status:-0}
  printf '%s\n' "$output"
  token=$(printf '%s' "$output" | sed -n 's/.*[?&]token=\([0-9a-f]\{8,\}\).*/\1/p' | head -1)
  if [ -z "$token" ]; then
    echo "tools/trace.sh: no token in the command's output; pass --token" >&2
    exit 1
  fi
  printf '\n--- trace ---\n'
  curl -s "$(trace_url "")"
  exit "$status"
fi

NIIMBENCH_TOKEN="$token"
export NIIMBENCH_TOKEN
curl -s "$(trace_url "?clear=1")" >/dev/null
status=0
"$@" || status=$?
printf '\n--- trace ---\n'
curl -s "$(trace_url "")"
exit "$status"
