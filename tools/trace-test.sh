#!/bin/sh
# Read back the trace from one boot of the page and insist it is complete.
#
#   tools/trace-test.sh <browser>
#
# This is the harness for finding out what the editor did. The server is
# tools/with-server.sh's, which starts a throwaway one for this script and
# stops it after; the page is loaded once in a headless browser, and
# `tools/trace-test.js` reads the trace both sides wrote and checks it against
# the protocol.
#
# When something is wrong, run this first: it prints the whole trace, so the
# answer is in front of you instead of being inferred from a screenshot.
set -eu

browser="${1:?usage: trace-test.sh <browser>}"
[ -n "${NIIMBENCH_PID:-}" ] || exec "$(dirname "$0")/with-server.sh" "$0" "$@"

status=0
node "$(dirname "$0")/trace-test.js" --chrome "$browser" --url "$NIIMBENCH_URL" --timeout "${TRACE_BUDGET_MS:-30000}" || status=$?
exit "$status"
