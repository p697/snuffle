#!/bin/bash
# Renders every poster of index.html to out/<lang>/<n>.png at 1320 × 2868 with headless Chrome, the six posters of a
# language in parallel, then writes out/<lang>/upload/<n>.png at 1206 × 2622 without alpha: the size App Store Connect
# requires ("iPhone with Dynamic Island, medium display"; it scales those for every other iPhone).
# Usage: ./render.sh [lang ...]   (default: every language in copy.js). Needs python3 with Pillow.
set -euo pipefail
cd "$(dirname "$0")"
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
langs=("$@")
if [ ${#langs[@]} -eq 0 ]; then
  while IFS= read -r lang; do langs+=("$lang"); done < <(node -e 'global.window = {}; require("./copy.js"); console.log(Object.keys(window.COPY).join("\n"))')
fi
profiles=$(mktemp -d)
trap 'rm -rf "$profiles"' EXIT
for lang in "${langs[@]}"; do
  mkdir -p "out/$lang"
  for shot in 1 2 3 4 5 6; do
    # Each Chrome needs its own profile to run side by side.
    "$chrome" --headless=new --hide-scrollbars --force-device-scale-factor=1 --window-size=1320,2868 \
      --user-data-dir="$profiles/$shot" --virtual-time-budget=10000 --screenshot="out/$lang/$shot.png" \
      "file://$PWD/index.html?lang=$lang&shot=$shot" >/dev/null 2>&1 &
  done
  wait
  python3 - "out/$lang" <<'PY'
import os, sys
from PIL import Image
folder = sys.argv[1]
os.makedirs(f"{folder}/upload", exist_ok=True)
for shot in range(1, 7):
    Image.open(f"{folder}/{shot}.png").convert("RGB").resize((1206, 2622), Image.LANCZOS).save(f"{folder}/upload/{shot}.png", optimize=True)
PY
  echo "$lang"
done
