#!/usr/bin/env bash
# Fast-forward the owner's primary checkout to origin/main. Run it from any worktree after a merge.
# An Xcode build running from the primary checkout is waited out; a dirty or off-main checkout is never touched.
# Exit 0: synced. 2: dirty or not on main (report it). 3: a build outlasted the wait. 4: origin unreachable.
set -euo pipefail

primary=$(git -C "$(dirname "${BASH_SOURCE[0]}")" worktree list --porcelain | awk 'NR == 1 { print $2 }')
cd "$primary"
wait_seconds=${SYNC_WAIT_SECONDS:-3600}

guard() {
  if [ "$(git branch --show-current)" != main ] || [ -n "$(git status --porcelain)" ]; then
    echo "Primary checkout $primary is dirty or not on main; left untouched." >&2
    exit 2
  fi
}

guard
waited=0
while pgrep -f "xcodebuild.*$primary/" >/dev/null; do
  if [ "$waited" -ge "$wait_seconds" ]; then
    echo "An Xcode build in $primary is still running after ${waited}s; run this again later." >&2
    exit 3
  fi
  [ "$waited" -gt 0 ] || echo "Waiting for the Xcode build in the primary checkout to finish…"
  sleep 30
  waited=$((waited + 30))
done

for attempt in 1 2 3; do
  git fetch -q origin && break
  [ "$attempt" = 3 ] && { echo "Could not fetch origin; primary checkout untouched." >&2; exit 4; }
  sleep 10
done
guard
git merge -q --ff-only origin/main
echo "Primary checkout at $(git log --oneline -1)"
