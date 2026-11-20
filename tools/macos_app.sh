#!/usr/bin/env bash
# Puts the built binary into a macOS app bundle: Majestic Media Player.app.
# Usage: tools/macos_app.sh BINARY APP
set -euo pipefail
cd "$(dirname "$0")/.."
bin=$1 app=$2
[[ $app == *.app ]] || { echo "not an app bundle path: $app" >&2; exit 2; }
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
nim r --hints:off --warnings:off -d:release tools/make_app.nim "$app" "$(basename "$bin")"
iconutil -c icns -o "$app/Contents/Resources/majestic-media-player.icns" \
  "$app/Contents/Resources/majestic-media-player.iconset"
rm -rf "$app/Contents/Resources/majestic-media-player.iconset"
cp "$bin" "$app/Contents/MacOS/"
# Ad hoc signature over the whole bundle, so macOS ties its permissions (the
# visualizer's audio capture) to the app.
codesign --force --sign - "$app" >/dev/null 2>&1 || echo "codesign failed; the app may not start" >&2
echo "Built $app."
