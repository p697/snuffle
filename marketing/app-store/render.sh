#!/bin/bash
# Renders every poster of index.html to out/<lang>/<n>.png at 1320 × 2868 with headless Chrome, the six posters of a
# language in parallel. Usage: ./render.sh [lang ...]   (default: every language in copy.js)
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
  echo "$lang"
done
