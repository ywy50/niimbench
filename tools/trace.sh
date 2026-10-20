#!/bin/sh
# Report what niimbench did around one command.
#
# The trace plugin keeps a log in the running server (docs/subsystems/trace.md).
# This clears it, runs the command you give it, and prints only the lines that
# appeared, so the output is about that command and nothing else.
#
#   tools/trace.sh -- curl -s ...
#   tools/trace.sh --url http://127.0.0.1:8080 --token abc123 -- curl -s ...
#
# The command is run exactly as written, so quote it the way you would type it.
# It also gets `NIIMBENCH_URL` and `NIIMBENCH_TOKEN` in its environment, so a
# curl inside it does not have to be told the token twice.
#
# `--port` is a shortcut for `--url http://127.0.0.1:PORT`. Without `--token`
# the address and token are those of the server running from this folder, read
# from the `.niimbench.token` file it writes, as `make trace` reads them. The
# server has to be running already: one started by COMMAND would be gone, with
# its log, by the time COMMAND returns.
set -eu

usage() {
  cat <<'EOF'
usage: tools/trace.sh [--url URL] [--port PORT] [--token TOKEN] -- COMMAND [ARGS...]

  --url URL     where the server is listening (default http://127.0.0.1:8080)
  --port PORT   shorthand for --url http://127.0.0.1:PORT
  --token TOK   the session token; without it, the URL and token come from
                .niimbench.token, which the server running here writes
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

if [ -z "$token" ]; then
  if [ ! -r .niimbench.token ]; then
    echo "tools/trace.sh: no .niimbench.token here: start the server in this folder, or pass --url and --token" >&2
    exit 1
  fi
  startup=$(cat .niimbench.token)
  token=${startup##*token=}
  if [ -z "$port" ] && [ "$url" = "http://127.0.0.1:8080" ]; then url=${startup%%/\?token=*}; fi
fi

# The log's URL, with `clear=1` or nothing as its one extra parameter.
trace_url() {
  printf '%s/api/trace?token=%s%s' "$url" "$token" "${1:+&$1}"
}

NIIMBENCH_URL="$url"
NIIMBENCH_TOKEN="$token"
export NIIMBENCH_URL NIIMBENCH_TOKEN
# -f, so a server that is gone or a wrong token fails here instead of
# printing an old log as if it were this command's.
curl -fsS "$(trace_url "clear=1")" >/dev/null
status=0
"$@" || status=$?
printf '\n--- trace ---\n'
curl -fsS "$(trace_url "")"
exit "$status"
