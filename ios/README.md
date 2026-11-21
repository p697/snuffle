# Snuffle for iPhone

SwiftUI app (iOS 18+), a widget extension, and `SnuffleKit`, the package both share.

## Layout

- `Packages/SnuffleKit` — models, the PostHog / RevenueCat / App Store Connect / Google Play clients, OAuth (PKCE),
  Keychain storage, the demo world and the refresh logic. Builds for macOS too, so its tests run with `swift test`.
- `Snuffle/` — the app. `App/AppModel.swift` owns state and the refresh choreography; `Design/` holds the odometer,
  the cat and the refresh button; one folder per tab.
- `SnuffleWidgets/` — home and lock screen widgets with an in-widget refresh button.
- `SnuffleUITests/` — end-to-end tests in demo mode.
- `scripts/render-icon.swift` — draws the app icons from the design's geometry.

## Build and test

```bash
cd ios && xcodegen generate
```

```bash
cd ios/Packages/SnuffleKit && swift test
```

```bash
cd ios && xcodebuild test -project Snuffle.xcodeproj -scheme Snuffle -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

The run scheme uses `Snuffle/Products.storekit`, so purchases work in the simulator without App Store Connect.

## Configuration

`Config/Shared.xcconfig` holds runtime values. The drafting API defaults to `https://snuffle.ai`; override it, and
add the Google client id, in `Config/Local.xcconfig` (git-ignored):

```
SNUFFLE_API_URL = http:/$()/127.0.0.1:8787   // a local `wrangler dev`, see server/README.md
SNUFFLE_GOOGLE_CLIENT_ID = <iOS OAuth client id>
```

Without a Google client id the app still works; Google Play sign-in is hidden.

## Launch arguments (debug)

- `-demo` starts in demo mode; `-scenario sale|quiet|failure` shapes the next demo refresh.
- `-resetState` clears saved projects, settings and caches.
- `-forcePro` unlocks Pro in debug builds only.
