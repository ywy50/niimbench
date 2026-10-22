#!/bin/sh
# Start niimbench.app the way Finder does, and check what the app is for: it
# serves; it survives a printer scan, both kinds, as the app; a second start
# opens the running one instead of starting a second server; Quit stops it;
# and it leaves no token file behind. When the server dies, the crash report
# macOS wrote for it is printed, which says why.
#
#   tools/macos-app-check.sh [APP]
#
# APP defaults to zig-out/macos/niimbench.app, which tools/macos-app.sh builds.
# macOS only. It uses this user's Application Support folder, which is where
# the app keeps its lock and token file, and refuses to run while a niimbench
# app server is already running, so it never stops one that someone uses.
set -eu

app=${1:-zig-out/macos/niimbench.app}
state="$HOME/Library/Application Support/niimbench"
token="$state/.niimbench.token"

# The newest crash report macOS wrote for the server, from the user's own
# DiagnosticReports folder, which is where an app's go.
report() {
  latest=$(ls -t "$HOME"/Library/Logs/DiagnosticReports/niimbench*.ips 2>/dev/null | head -1)
  [ -n "$latest" ] || { echo "macos-app-check: no crash report for niimbench" >&2; return; }
  echo "macos-app-check: crash report $latest" >&2
  head -c 20000 "$latest" >&2
}
fail() { echo "macos-app-check: $*" >&2; report; exit 1; }
servers() { pgrep -f "Helpers/niimbench.app/Contents/MacOS/niimbench" | wc -l | tr -d ' '; }
settle() { i=0; while [ "$(servers)" != "$1" ] && [ $i -lt 100 ]; do i=$((i + 1)); sleep 0.1; done; }

[ -d "$app" ] || fail "no $app; build it with tools/macos-app.sh"
[ "$(servers)" = 0 ] || fail "a niimbench app server is already running; quit it first"
rm -f "$token"

open "$app"
i=0
while [ ! -s "$token" ] && [ $i -lt 300 ]; do i=$((i + 1)); sleep 0.1; done
[ -s "$token" ] || fail "no token file in $state 30 s after the app started"
url=$(cat "$token")
base=${url%%/\?token=*}
secret=${url##*token=}
quit() { curl -fsS --max-time 60 -X POST "$base/api/quit?token=$secret" >/dev/null 2>&1 || true; }
trap quit EXIT

# The browser the app opened may have the page scanning for printers, which
# can hold the one-request-at-a-time server for as long as macOS takes to
# answer about Bluetooth, so the answer gets time.
curl -fsS --max-time 60 "$base/api/health?token=$secret" >/dev/null || fail "the app's server does not answer at $base"
echo "serves at $base"

# A scan is the first thing that reaches CoreBluetooth, and the first time it
# does so as the app rather than from a terminal. CI's Macs have no radio, so
# the answer is why it cannot listen; what matters is that the server is
# still there to give it.
for discover in false true; do
  answer=$(curl -sS --max-time 90 -X POST "$base/api/devices/scan?token=$secret" --data-binary "{\"discover\":$discover}") ||
    fail "the server died during a scan with discover $discover"
  echo "scan, discover $discover: $answer"
  curl -fsS --max-time 10 "$base/api/health?token=$secret" >/dev/null || fail "the server died after a scan with discover $discover"
done

open "$app"
sleep 3
settle 1
[ "$(servers)" = 1 ] || fail "a second start left $(servers) servers running"
echo "a second start opened the running one"

quit
trap - EXIT
settle 0
[ "$(servers)" = 0 ] || fail "the server still runs after Quit"
[ ! -e "$token" ] || fail "the token file outlived the server"
echo "macos app ok"
