#!/bin/sh
# niimbench.app as Finder starts it. The server is the app inside it,
# Contents/Helpers/niimbench.app, started as an app of its own: macOS asks
# whether it may use Bluetooth by that app's name and Info.plist, and this
# launcher ends at once.
#
# A double-click on an app that is still running only brings it forward, so a
# launcher that stayed would turn every later double-click into nothing. This
# one is started anew each time, and `open -n` starts the server anew as well:
# a second server finds the first one's lock, opens its page and exits.
here=$(cd "$(dirname "$0")/.." && pwd)
exec /usr/bin/open -n -a "$here/Helpers/niimbench.app" --args --app
