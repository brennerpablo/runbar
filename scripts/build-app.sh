#!/bin/bash
# Builds Runbar and assembles build/Runbar.app.
#   scripts/build-app.sh            build only
#   scripts/build-app.sh --install  install to /Applications, link the `runbar` command and open the app
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="dev.runbar.Runbar"
VERSION="0.1.0"
CONFIG="${CONFIG:-release}"

echo "→ building ($CONFIG)…"
swift build -c "$CONFIG" --product RunbarApp
swift build -c "$CONFIG" --product runbar
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/Runbar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/RunbarApp" "$APP/Contents/MacOS/Runbar"
cp "$BIN/runbar" "$APP/Contents/Helpers/runbar"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Runbar</string>
  <key>CFBundleDisplayName</key><string>Runbar</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>Runbar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Runbar</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP/Contents/Helpers/runbar" >/dev/null
codesign --force --sign - "$APP" >/dev/null
echo "✓ $APP"

if [[ "${1:-}" == "--install" ]]; then
  # /Applications, where the download goes too, so there's one copy; ~/Applications if it isn't writable.
  APPS="/Applications"
  [[ -w "$APPS" ]] || APPS="$HOME/Applications"
  DEST="$APPS/Runbar.app"
  mkdir -p "$APPS"
  # Plain SIGTERM: the app quits without stopping services, and the new process re-adopts them all.
  pkill -x Runbar 2>/dev/null && sleep 1 || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "✓ installed at $DEST"

  for dir in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
    if [[ -d "$dir" && -w "$dir" ]]; then
      if [[ -e "$dir/runbar" && ! -L "$dir/runbar" ]]; then continue; fi
      ln -sf "$DEST/Contents/Helpers/runbar" "$dir/runbar"
      echo "✓ runbar command at $dir/runbar"
      break
    fi
  done

  open "$DEST"
fi
