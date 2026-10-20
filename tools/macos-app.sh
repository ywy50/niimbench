#!/bin/sh
# Build niimbench.app, the Mac app, and the zip a release ships it in.
#
#   tools/macos-app.sh [OUT]
#
# OUT defaults to zig-out/macos and receives niimbench.app,
# niimbench-macos.zip and niimbench-macos.zip.sha256. It runs on macOS, which
# has the tools a bundle needs: lipo, sips, iconutil, plutil, codesign and
# ditto. The two binaries it joins build anywhere, because niimbench links
# nothing from Apple's SDK (src/corebluetooth.zig).
#
# The bundle is two apps, the launcher Finder starts and the server inside it
# (packaging/macos/launcher.sh says why). Both are signed ad hoc: macOS runs
# nothing unsigned on Apple silicon, and a signature that seals the bundle is
# what lets a downloaded copy be opened at all. It is not a Developer ID
# signature and the app is not notarized, so the first open needs the person's
# say-so; README.md walks through it.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-$root/zig-out/macos}
case "$out" in /*) ;; *) out=$(pwd)/$out ;; esac
version=$(sed -n 's/^ *\.version = "\([^"]*\)",.*/\1/p' "$root/build.zig.zon" | head -1)
[ -n "$version" ] || { echo "macos-app: no .version in build.zig.zon" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$root"

# One binary for both kinds of Mac. 13.0 is the oldest macOS Zig targets, and
# the Info.plists say the same.
for arch in aarch64 x86_64; do
  zig build -Doptimize=ReleaseSafe -Dtarget="$arch-macos.13.0" --prefix "$work/$arch"
done

app="$out/niimbench.app"
server="$app/Contents/Helpers/niimbench.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$server/Contents/MacOS" "$server/Contents/Resources"

lipo -create "$work/aarch64/bin/niimbench" "$work/x86_64/bin/niimbench" -output "$server/Contents/MacOS/niimbench"
cp packaging/macos/launcher.sh "$app/Contents/MacOS/niimbench"
chmod 755 "$app/Contents/MacOS/niimbench" "$server/Contents/MacOS/niimbench"
sed "s/@VERSION@/$version/g" packaging/macos/Info.plist > "$app/Contents/Info.plist"
sed "s/@VERSION@/$version/g" packaging/macos/Server-Info.plist > "$server/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" "$server/Contents/Info.plist"
# What CI's Macs cannot catch by running the app, checked by reading it: macOS
# ends an app that reaches for Bluetooth without saying why in its Info.plist,
# and either app without LSUIElement would sit in the Dock answering nothing.
plist_has() { [ "$(plutil -extract "$2" raw -o - "$1" 2>/dev/null)" = "$3" ] || { echo "macos-app: $1 has no $2 = $3" >&2; exit 1; }; }
plutil -extract NSBluetoothAlwaysUsageDescription raw -o - "$server/Contents/Info.plist" >/dev/null ||
  { echo "macos-app: the server's Info.plist does not say why it uses Bluetooth" >&2; exit 1; }
plist_has "$app/Contents/Info.plist" LSUIElement true
plist_has "$server/Contents/Info.plist" LSUIElement true

# The icon, every size Finder asks for, from the one 1024-pixel picture.
iconset="$work/niimbench.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" packaging/macos/icon-1024.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" packaging/macos/icon-1024.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/niimbench.icns"
cp "$app/Contents/Resources/niimbench.icns" "$server/Contents/Resources/niimbench.icns"

# Inside out: the server first, then the launcher, whose seal covers it.
codesign --force --sign - "$server"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"

# The bundle proves what it carries before it ships.
archs=$(lipo -archs "$server/Contents/MacOS/niimbench")
case "$archs" in
  *arm64*x86_64* | *x86_64*arm64*) ;;
  *) echo "macos-app: the server is $archs, not arm64 and x86_64" >&2; exit 1 ;;
esac
reported=$("$server/Contents/MacOS/niimbench" --version | awk '{print $2}')
[ "$reported" = "$version" ] || { echo "macos-app: the server reports $reported, build.zig.zon says $version" >&2; exit 1; }

# ditto keeps what a plain zip drops from a bundle, the signature included.
rm -f "$out/niimbench-macos.zip" "$out/niimbench-macos.zip.sha256"
(cd "$out" && ditto -c -k --keepParent niimbench.app niimbench-macos.zip && shasum -a 256 niimbench-macos.zip > niimbench-macos.zip.sha256)
echo "macos-app: $out/niimbench.app ($archs), $version"
cat "$out/niimbench-macos.zip.sha256"
