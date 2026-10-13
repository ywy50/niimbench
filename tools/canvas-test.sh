#!/bin/sh
# Check the canvas the page actually draws.
#
#   tools/canvas-test.sh <browser> [browser args...]
#
# Browser-agnostic: the page classifies its own canvas and writes the verdict
# into the DOM, and any Chromium-family browser can print that DOM with
# `--dump-dom`. Chromium, Chrome, Edge and Chromium headless-shell all accept
# those flags; nothing here speaks a debugging protocol, so there is nothing to
# time out and nothing to keep in step with a browser version.
#
# The server is started in a temporary working directory of its own, because the
# single-server lock is per directory: a server left running in this checkout
# cannot block the check, and the check cannot block it.
#
# To check a page some other way, dump its DOM yourself and pass the file:
#
#   tools/canvas.test.js --dump dom.html
set -eu

browser="${1:?usage: canvas-test.sh <browser> [browser args...]}"
shift
dir=$(mktemp -d)
server_log="$dir/server.log"
dom="$dir/dom.html"

cleanup() {
  if [ -n "${server_pid:-}" ]; then kill "$server_pid" 2>/dev/null || true; fi
  rm -rf "$dir"
}
trap cleanup EXIT INT TERM

binary="$(pwd)/zig-out/bin/niimbench"
[ -x "$binary" ] || { echo "canvas-test: $binary is missing; run make build first"; exit 1; }

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
  echo "canvas-test: the server never printed a URL:"
  sed 's/^/  /' "$server_log"
  exit 1
fi

# A URL on stdout is a promise, not a fact.
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

# Virtual time makes the wait a number rather than a guess: the browser runs the
# page's timers as fast as it can and dumps the DOM when the budget is spent.
"$browser" \
  --headless=new \
  --disable-gpu \
  --no-sandbox \
  --disable-dev-shm-usage \
  --user-data-dir="$dir/profile" \
  --virtual-time-budget="${CANVAS_BUDGET_MS:-30000}" \
  --dump-dom \
  "$@" \
  "$url#selfcheck" > "$dom" 2>"$dir/browser.log" || true

if [ "${CANVAS_VERBOSE:-}" = "1" ] || [ ! -s "$dom" ]; then
  echo "browser stderr:"
  sed 's/^/  /' "$dir/browser.log" | head -20
fi

status=0
node "$(dirname "$0")/canvas.test.js" --dump "$dom" || status=$?

# The layout the docs hand out must be one the server draws: a template naming
# a font or a field the server refuses would load in the editor and then fail
# its first render.
template="$(dirname "$0")/../docs/templates/example-label.json"
base=${url%%\?*}
token=${url##*token=}
code=$(curl -sS -o "$dir/template.json" -w '%{http_code}' -X POST -H 'content-type: application/json' \
  --data-binary "@$template" "${base}api/render?token=$token" || echo 000)
if [ "$code" = "200" ] && grep -q '"pixels_b64"' "$dir/template.json"; then
  echo "template ok"
else
  echo "canvas-test: POST /api/render answered $code to docs/templates/example-label.json: $(head -c 200 "$dir/template.json" 2>/dev/null)"
  status=1
fi
exit "$status"
