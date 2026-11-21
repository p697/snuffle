# Snuffle for iPhone

SwiftUI app (iOS 18+), a widget extension, and `SnuffleKit`, the package both share.

## Layout

- `Packages/SnuffleKit` — models, the PostHog / RevenueCat / App Store Connect / Google Play clients, OAuth (PKCE),
  Keychain storage, the demo world and the refresh logic. Builds for macOS too, so its tests run with `swift test`.
- `Snuffle/` — the app. `App/AppModel.swift` owns state and the refresh choreography; `Design/` holds the odometer,
  the cat and the refresh button; one folder per tab.
- `SnuffleWidgets/` — home and lock screen widgets with an in-widget refresh button.
- `Shared/` — compiled into both the app and the widgets: the widget data (`TodayEntry`) and faces, so the
  paywall's widget preview is drawn by the same code as the real widget.
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

`Config/Shared.xcconfig` holds runtime values: the drafting API (`https://snuffle.ai`) and the iOS OAuth client of
the "Snuffle" Google Cloud project, which has the Google Play Android Developer API (reviews) and the Play Developer
Reporting API (listing the account's apps) enabled. While its consent screen is in testing, only listed test users can
sign in. Override values in `Config/Local.xcconfig` (git-ignored), e.g. a local server:

```
SNUFFLE_API_URL = http:/$()/127.0.0.1:8787   // a local `wrangler dev`, see server/README.md
```

## Launch arguments (debug)

- `-demo` starts in demo mode; `-scenario sale|quiet|failure` shapes the next demo refresh.
- `-resetState` clears saved projects, settings and caches.
- `-forcePro` unlocks Pro in debug builds only.

## Release

The App Store record is "Snuffle" (`ai.snuffle.app`, team C8TM82D73W); the Pro products are already configured in
App Store Connect with the same ids as `Products.storekit`. Build from the latest `main` with the script at the repository root (it syncs and builds the primary checkout):

```
scripts/ios-build.sh device       # Release build on the iPhone connected by cable
scripts/ios-build.sh testflight   # archive and upload; the build number is the commit count of main
```

Signing uses the Apple ID signed into Xcode. Bump `MARKETING_VERSION` in `project.yml` for a new version.
`ExportOptions.plist` uses `method` `app-store-connect` and `destination` `upload`. `PrivacyInfo.xcprivacy` in each
target declares the App Group defaults and no collected data while drafting is hidden; keep it in step with the App
Store privacy answers.
