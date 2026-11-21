#!/bin/bash
# Packs Runbar into build/Runbar.dmg: the app and a link to /Applications to drag it onto (make dmg).
# Apple silicon only, signed ad hoc and not notarized (no Developer ID yet): the first time it opens, macOS
# blocks it until System Settings › Privacy & Security › Open Anyway.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R build/Runbar.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f build/Runbar.dmg
hdiutil create -quiet -volname Runbar -srcfolder "$STAGE" -fs HFS+ -format UDZO build/Runbar.dmg
echo "✓ build/Runbar.dmg ($(du -h build/Runbar.dmg | cut -f1 | tr -d ' '))"
