#!/usr/bin/env bash
# Build Snuffle from the primary checkout at the latest main, so every build maps to one merged commit.
#   scripts/ios-build.sh device       Release build, installed and launched on the iPhone connected by cable
#   scripts/ios-build.sh testflight   archive and upload to App Store Connect; build number = commits on main
# Signing uses the Apple ID signed into Xcode. Unmerged work is tested in its worktree, not packaged.
set -euo pipefail

mode=${1:-device}
case "$mode" in device | testflight) ;; *) echo "usage: scripts/ios-build.sh [device|testflight]" >&2; exit 2 ;; esac

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
bash "$here/sync-primary-checkout.sh"
primary=$(git -C "$here" worktree list --porcelain | awk 'NR == 1 { print $2 }')
cd "$primary/ios"
commit=$(git rev-parse --short HEAD)
xcodegen generate --quiet

if [ "$mode" = device ]; then
  list=$(mktemp)
  trap 'rm -f "$list"' EXIT
  xcrun devicectl list devices -q --json-output "$list"
  udid=$(python3 -c '
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    h, c = d["hardwareProperties"], d["connectionProperties"]
    if h.get("reality") == "physical" and h.get("deviceType") == "iPhone" and c.get("transportType") == "wired":
        print(h["udid"]); break
' "$list")
  [ -n "$udid" ] || { echo "No iPhone connected by cable." >&2; exit 1; }
  xcodebuild build -quiet -project Snuffle.xcodeproj -scheme Snuffle -configuration Release \
    -destination "id=$udid" -derivedDataPath "$primary/ios/build/device" -allowProvisioningUpdates
  xcrun devicectl device install app -q --device "$udid" "$primary/ios/build/device/Build/Products/Release-iphoneos/Snuffle.app"
  echo "Installed main $commit on $udid"
  # A locked phone refuses the launch; the install has already succeeded.
  xcrun devicectl device process launch -q --device "$udid" ai.snuffle.app >/dev/null 2>&1 \
    || echo "The phone is locked: unlock it and open Snuffle."
else
  build=$(git rev-list --count HEAD)
  out="$primary/ios/build/release/$build"
  xcodebuild archive -quiet -project Snuffle.xcodeproj -scheme Snuffle -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$out/Snuffle.xcarchive" -allowProvisioningUpdates \
    CURRENT_PROJECT_VERSION="$build"
  xcodebuild -exportArchive -quiet -archivePath "$out/Snuffle.xcarchive" -exportOptionsPlist ExportOptions.plist \
    -exportPath "$out/export" -allowProvisioningUpdates
  echo "Uploaded build $build from main $commit"
fi
