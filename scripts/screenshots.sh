#!/bin/bash
# Redraws the README's screenshots into docs/assets, light and dark, from made-up projects and services
# (DemoShots.swift, debug builds only). Nothing is read from this Mac but the wallpaper behind the panels:
# WALLPAPER_LIGHT and WALLPAPER_DARK, by default .wallpapers/light.jpg and dark.jpg (macOS Sequoia's, 6K,
# from 512pixels.net; kept out of git). Without them the shots draw a backdrop of their own.
# Needs cwebp (brew install webp).
set -euo pipefail
cd "$(dirname "$0")/.."

command -v cwebp >/dev/null || { echo "cwebp not found: brew install webp"; exit 1; }
echo "→ building (debug)…"
swift build --product RunbarApp
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
[[ -z "${WALLPAPER_LIGHT:-}" && -f .wallpapers/light.jpg ]] && export WALLPAPER_LIGHT="$PWD/.wallpapers/light.jpg"
[[ -z "${WALLPAPER_DARK:-}" && -f .wallpapers/dark.jpg ]] && export WALLPAPER_DARK="$PWD/.wallpapers/dark.jpg"
.build/debug/RunbarApp --readme-shots "$OUT" >/dev/null
mkdir -p docs/assets
for png in "$OUT"/*.png; do
  cwebp -quiet -q 90 "$png" -o "docs/assets/$(basename "$png" .png).webp"
done
echo "✓ docs/assets"
