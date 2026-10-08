#!/bin/zsh
# Builds ~/Applications/Gauge.app (Claude Gauge), runs the self-test, renders the icon, and relaunches it.
#   ./build.sh              build + install + launch
#   ./build.sh --snapshot D also render review PNGs into D
set -euo pipefail
cd "${0:A:h}"
APP=~/Applications/Gauge.app
BIN="$APP/Contents/MacOS/Gauge"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -parse-as-library -O -target "$(uname -m)-apple-macosx14.0" *.swift -o "$BIN"
"$BIN" --selftest

ICONSET=$(mktemp -d)/AppIcon.iconset && mkdir -p "$ICONSET"
"$BIN" --icon "$ICONSET/icon_512x512@2x.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>app.claudegauge.mac</string>
  <key>CFBundleName</key><string>Gauge</string>
  <key>CFBundleDisplayName</key><string>Claude Gauge</string>
  <key>CFBundleExecutable</key><string>Gauge</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>3.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"

if [[ "${1:-}" == "--snapshot" ]]; then
  mkdir -p "$2" && "$BIN" --snapshot "$2" && echo "snapshots in $2"
fi
pkill -x Gauge || true
open "$APP"
