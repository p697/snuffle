#!/bin/bash
# Takes the simulator screenshots the posters use, for each language, into screens/<lang>/:
#   home-rest.png  the home screen at rest          (poster 1)
#   money.png      the revenue tab                   (poster 2)
#   home.png       home right after a refresh that found something, cat out (poster 3)
#   reviews.png    the reviews tab                   (poster 4)
#   widget.png     the Home Screen with the medium Snuffle widget (poster 5)
#
# Needs: a booted iPhone 17 Pro Max simulator (1320 × 2868) with a debug build of the app installed and the medium
# "今日" widget already placed at the top of its Home Screen (add it once by hand), plus python3 with Pillow.
# Each language reboots the simulator in that language, so the app, the widget and the Home Screen all switch.
#
# Usage: SIM=<udid> ./capture.sh [lang ...]   (default: every language in copy.js)
set -euo pipefail
cd "$(dirname "$0")"
: "${SIM:?set SIM to the simulator UDID}"
app=ai.snuffle.app
base=(-noAnalytics -demo -forcePro -storeShots)

locale_for() {
  case "$1" in
    zh-Hans) echo zh_CN ;; zh-Hant) echo zh_TW ;; es-419) echo es_MX ;; pt-BR) echo pt_BR ;; pt-PT) echo pt_PT ;;
    en) echo en_US ;; ja) echo ja_JP ;; ko) echo ko_KR ;; de) echo de_DE ;; es) echo es_ES ;; fr) echo fr_FR ;;
    it) echo it_IT ;; ru) echo ru_RU ;; uk) echo uk_UA ;; tr) echo tr_TR ;; vi) echo vi_VN ;; th) echo th_TH ;;
    hi) echo hi_IN ;; ar) echo ar_SA ;; *) echo "unknown language $1" >&2; exit 1 ;;
  esac
}

shot() { xcrun simctl io "$SIM" screenshot "$1" >/dev/null 2>&1; }

launch() {
  xcrun simctl terminate "$SIM" "$app" >/dev/null 2>&1 || true
  xcrun simctl launch "$SIM" "$app" "${base[@]}" "$@" >/dev/null
}

langs=("$@")
if [ ${#langs[@]} -eq 0 ]; then
  while IFS= read -r lang; do langs+=("$lang"); done < <(node -e 'global.window = {}; require("./copy.js"); console.log(Object.keys(window.COPY).join("\n"))')
fi

for lang in "${langs[@]}"; do
  out="screens/$lang"
  mkdir -p "$out/burst"
  rm -f "$out"/burst/*.png

  xcrun simctl spawn "$SIM" defaults write "Apple Global Domain" AppleLanguages -array "$lang"
  xcrun simctl spawn "$SIM" defaults write "Apple Global Domain" AppleLocale "$(locale_for "$lang")"
  xcrun simctl shutdown "$SIM" >/dev/null 2>&1 || true
  xcrun simctl boot "$SIM"
  xcrun simctl bootstatus "$SIM" >/dev/null 2>&1
  xcrun simctl status_bar "$SIM" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 --dataNetwork wifi
  sleep 4

  # A fresh demo day with one refresh behind it, so the home screen shows "N minutes ago".
  launch -resetState -scenario sale -refreshAfterLaunch
  sleep 12
  launch
  sleep 4; shot "$out/home-rest.png"
  launch -tab money
  sleep 4; shot "$out/money.png"
  launch -tab reviews
  sleep 4; shot "$out/reviews.png"

  # Refresh with a sale coming in and keep shooting; pick the frame below.
  launch -scenario sale -refreshAfterLaunch
  for i in $(seq -w 1 60); do shot "$out/burst/$i.png"; done

  # Leaving the app shows the Home Screen; the refresh above reloaded the widget.
  xcrun simctl terminate "$SIM" "$app"
  sleep 4; shot "$out/widget.png"

  # The refresh frame: every card landed, highlights on, cat still out. The cat leaves a few frames after the last
  # card lands, so take the frame before its last one.
  python3 - "$out" <<'PY'
import glob, shutil, sys
from PIL import Image
out = sys.argv[1]
def cat(image):  # the head above the button is dark; at rest only ear tips show, below this band
    return sum(1 for p in image.crop((590, 2380, 730, 2470)).getdata() if max(p) < 70)
def highlights(image):
    return sum(1 for r, g, b in image.crop((40, 600, 1280, 2300)).resize((310, 425)).getdata() if r > 230 and g > 190 and b < 110)
frames = sorted(glob.glob(f"{out}/burst/*.png"))
good = [f for f in frames if (lambda image: cat(image) > 3000 and highlights(image) > 500)(Image.open(f).convert("RGB"))]
if len(good) < 2:
    sys.exit(f"{out}: no refresh frame with the cat out and highlights on")
shutil.copy(good[-2], f"{out}/home.png")
PY
  rm -rf "$out/burst"
  echo "$lang"
done
