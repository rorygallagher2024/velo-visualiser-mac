#!/bin/bash
# Assemble Velo Visualiser.app from the SwiftPM build.
#
# There is no .xcodeproj on purpose: everything here is text, so the whole app
# is diffable and buildable from a terminal. The bundle matters even for a
# personal tool — Core Audio input is gated by TCC, and TCC only prompts for a
# signed bundle with a stable identifier.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="build/Velo Visualiser.app"

# Ensure git submodules (Ableton Link) are populated.
if [[ -f .gitmodules ]] && [[ ! -f Vendor/link/include/ableton/Link.hpp ]]; then
  echo "==> initialising submodules"
  git submodule update --init --recursive
fi

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG" --arch arm64

BIN=$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/Velo

echo "==> assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Velo"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
cp Resources/velo_logo.png "$APP/Contents/Resources/"
cp Resources/velo_v.png "$APP/Contents/Resources/"

# Icon: build an .icns from the shared 512 logo so the Mac app carries the same
# mark as the Android one.
# The SQUARE app icon, not velo_logo.png — that one is a 512x305 wordmark and
# sips -z stretches whatever it is given to the exact size asked for, which is
# how it ended up narrow in the Dock. app_icon_512.png is the dark-background
# mark, matching the Android launcher icon.
SRC_ICON="Resources/app_icon_512.png"
if [[ -f "$SRC_ICON" ]]; then
  W=$(sips -g pixelWidth "$SRC_ICON" | awk '/pixelWidth/{print $2}')
  H=$(sips -g pixelHeight "$SRC_ICON" | awk '/pixelHeight/{print $2}')
  if [[ "$W" != "$H" ]]; then
    echo "    WARNING: icon source is ${W}x${H}, not square — it will be distorted."
  fi
  ICONSET=$(mktemp -d)/AppIcon.iconset
  mkdir -p "$ICONSET"
  for sz in 16 32 64 128 256 512; do
    sips -z $sz $sz "$SRC_ICON" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null 2>&1 || true
    sips -z $((sz*2)) $((sz*2)) "$SRC_ICON" \
      --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null 2>&1 || true
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || \
    echo "    (icon skipped)"
fi

# Ad-hoc signature. Enough for TCC to remember the grant across launches, and
# it keeps the app off Gatekeeper's bad side on this machine.
echo "==> signing"
codesign --force --sign - --timestamp=none "$APP" >/dev/null

echo "==> done: $APP"
