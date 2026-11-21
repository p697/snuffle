# Snuffle

iPhone app (SwiftUI + widgets) that refreshes new users, revenue and store reviews across PostHog, RevenueCat,
App Store Connect and Google Play; plus the Cloudflare Worker on snuffle.ai. Layout and commands: `README.md` and
each folder's README. Product and architecture follow the code; fix docs you find stale.

## Branches, worktrees and merging

- The primary checkout `/Users/liuziwei/Desktop/snuffle-project/snuffle` is the owner's build directory. It stays
  on a clean `main` that matches origin/main. Never edit, switch, stash or reset it.
- Every task that changes files gets its own worktree and branch from the latest origin/main:

  ```bash
  git -C /Users/liuziwei/Desktop/snuffle-project/snuffle fetch origin
  git -C /Users/liuziwei/Desktop/snuffle-project/snuffle worktree add \
    ../worktrees/<task> -b <type>/<task> origin/main
  ```

  Never touch another task's worktree. Read-only research needs no worktree or PR.
- `main` only changes through pull requests. The `CI` check must pass and the branch must be up to date with main
  (GitHub rulesets), so every merge was tested against the main it lands on.
- After each push, run `pr-land <PR> --repo p697/snuffle` in the background. It merges once checks pass and
  updates a branch that fell behind (which reruns CI). Exit codes are in the script; 5/6/7 mean fix, push, rerun.
  Before merging, read the final diff against current main and keep only this task's changes. Resolve conflicts
  by merging origin/main into the branch, then rerun the affected checks.
- After `gh pr view <PR> --json state` says `MERGED` (never before): run `bash scripts/sync-primary-checkout.sh`
  from the worktree, then remove the worktree and delete the branch locally and on origin. A dirty or off-main
  primary checkout is left alone and reported.

## Builds and deploys

- Anything installed on the owner's iPhone or uploaded to TestFlight is built by `scripts/ios-build.sh device` or
  `scripts/ios-build.sh testflight`. Both sync the primary checkout and build it at the latest main, so a build
  always maps to a merged commit. Unmerged work is checked in its worktree (simulator or tests), not packaged,
  unless the owner asks to preview it.
- TestFlight uploads, App Store submissions and anything public need the owner's explicit go-ahead each time.
- snuffle.ai (server and site) deploys only through `.github/workflows/deploy.yml` on merge to main. Do not run
  `wrangler deploy` locally.

## Rules

- The repository is public. Never commit secrets, account or key ids, personal emails, or data from other
  companies' products. Secrets live in Worker secrets, GitHub secrets or the Keychain; never print them.
- UI text is Simplified Chinese. Code, comments, commits and docs are English.
- AI reply drafting is built but hidden (`Feature.replyDrafts` in `ios/Snuffle/App/CloudClient.swift`), so the app
  can ship in mainland China. Its comment lists everything to restore when turning it back on.
- Test what the change touches:
  - server or site: `cd server && pnpm install --frozen-lockfile && pnpm typecheck && pnpm test`
  - SnuffleKit: `cd ios/Packages/SnuffleKit && swift test`
  - app: `cd ios && xcodegen generate`, then `xcodebuild test -project Snuffle.xcodeproj -scheme Snuffle`
    on an iPhone simulator (Xcode 27).
  - docs only: nothing to build.
