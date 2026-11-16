#!/bin/bash
# Redraws the README's screenshots into docs/assets, light and dark, from made-up projects and services
# (DemoShots.swift, debug builds only). Nothing is read from this Mac. Needs cwebp (brew install webp).
set -euo pipefail
cd "$(dirname "$0")/.."

command -v cwebp >/dev/null || { echo "cwebp not found: brew install webp"; exit 1; }
echo "→ building (debug)…"
swift build --product RunbarApp
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
.build/debug/RunbarApp --readme-shots "$OUT" >/dev/null
mkdir -p docs/assets
for png in "$OUT"/*.png; do
  cwebp -quiet -q 90 "$png" -o "docs/assets/$(basename "$png" .png).webp"
done
echo "✓ docs/assets"
