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
# The server is tools/with-server.sh's, which starts a throwaway one for this
# script and stops it after.
#
# To check a page some other way, dump its DOM yourself and pass the file:
#
#   tools/canvas.test.js --dump dom.html
set -eu

browser="${1:?usage: canvas-test.sh <browser> [browser args...]}"
[ -n "${NIIMBENCH_PID:-}" ] || exec "$(dirname "$0")/with-server.sh" "$0" "$@"
shift
url=$NIIMBENCH_URL
dir=$(mktemp -d)
dom="$dir/dom.html"
trap 'rm -rf "$dir"' EXIT INT TERM

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
