# Snuffle for iPhone

SwiftUI app (iOS 18+), a widget extension, and `SnuffleKit`, the package both share.

## Layout

- `Packages/SnuffleKit` — models, the PostHog / RevenueCat / App Store Connect / Google Play clients, OAuth (PKCE),
  Keychain storage, the demo world and the refresh logic. Builds for macOS too, so its tests run with `swift test`.
- `Snuffle/` — the app. `App/AppModel.swift` owns state and the refresh choreography; `Design/` holds the odometer,
  the cat and the refresh button; `Cards/` the card and totals editors, the metric library, how new users and
  revenue are counted, and whose activity counts (`Scope.swift`: people numbers count only the `Surface`s a project
  includes, told apart by PostHog's `$lib`, `$os` and `$is_identified`; signed-out website visitors are left out
  unless they are all a project has); one folder per tab.
- `SnuffleWidgets/` — home and lock screen widgets with an in-widget refresh button.
- `SnuffleUITests/` — end-to-end tests in demo mode.
- `ANALYTICS.md` — the PostHog events, their properties and the metrics built on them.
- `scripts/render-icon.swift` — draws the app icons from the design's geometry.
- `scripts/localization.py` — syncs, checks and fills the string catalogs (see "Localization").

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

## Localization

The app, the widgets and SnuffleKit each have a `Localizable.xcstrings` (permission prompts:
`Snuffle/InfoPlist.xcstrings`). The source language is Simplified Chinese, written directly in the code; the other
18 languages are the ones YouMind ships: en, zh-Hant, ja, ko, de, es, es-419, fr, it, pt-BR, pt-PT, ru, uk, tr, vi,
th, hi, ar. A system language outside the list falls back to English (`CFBundleDevelopmentRegion`).

Writing strings:

- `Text("…")`, `Button("…")`, `Toggle`, `Label`, `.accessibilityLabel("…")` and other SwiftUI initializers taking a
  literal are localized. Anything that becomes a `String` first (a computed property, a ternary mixing literals and
  variables, a parameter typed `String`) needs `String(localized: "…")`. In SnuffleKit add `bundle: .module`.
- Interpolate whole values into one localized sentence (`String(localized: "\(count) 个项目")`); never concatenate
  translated fragments into a sentence. Joining finished pieces with " · " is fine.
- Counts: an `Int` interpolation becomes `%lld`; give plural forms where the language needs them (`apply` accepts
  `{"one": …, "other": …}`). Keep one count per string so plurals work. Numbers shown as text go through
  `Format.number` / `Format.money` (Latin digits, local separators, US dollars).
- User content and brand names are not keys: use `Text(verbatim:)` or a `String` variable for them.
- `// l10n-ignore` on a line exempts a literal that must stay as written (demo reviews in Japanese).

Translating, after building the app:

```bash
cd ios && python3 scripts/localization.py sync --derived-data build/dd
```

```bash
cd ios && python3 scripts/localization.py todo > /tmp/todo.json
```

Translate every listed key into all languages as `{"key": {"en": "…", "ja": "…", …}}` and merge it with
`python3 scripts/localization.py apply <file>`, then run `check` (also part of CI). Use the official App Store Connect,
Google Play Console and iOS terms of each language, keep placeholders and `**bold**`, and look at long languages
(de, ru) and Arabic (right to left) in the simulator; the `testLanguage_*` UI tests attach a
screenshot of each tab in every language.

## Configuration

`Config/Shared.xcconfig` holds runtime values: the drafting API (`https://snuffle.ai`) and the iOS OAuth client of
the "Snuffle" Google Cloud project, which has the Google Play Android Developer API (reviews) and the Play Developer
Reporting API (listing the account's apps) enabled. `SNUFFLE_POSTHOG_TOKEN` is the client token of Snuffle's own
PostHog project; leave it empty in `Local.xcconfig` to build without analytics. While its consent screen is in testing, only listed test users can
sign in. Override values in `Config/Local.xcconfig` (git-ignored), e.g. a local server:

```
SNUFFLE_API_URL = http:/$()/127.0.0.1:8787   // a local `wrangler dev`, see server/README.md
```

## Launch arguments (debug)

- `-demo` starts in demo mode; `-scenario sale|quiet|failure` shapes the next demo refresh.
- `-resetState` clears saved projects, settings and caches.
- `-forcePro` unlocks Pro in debug builds only.
- `-storeShots` hides demo mode's "示例" marks and starts a new demo day at 21:30; `-tab money|reviews|projects` opens on that tab; `-refreshAfterLaunch`
  presses the refresh button two seconds in. `marketing/app-store/capture.sh` uses them for the App Store screenshots.
- `-noAnalytics` keeps the PostHog SDK off (UI tests pass it; unit tests never start it).

## Release

The App Store record is "Snuffle" (`ai.snuffle.app`, team C8TM82D73W); the Pro products are already configured in
App Store Connect with the same ids as `Products.storekit`. Build from the latest `main` with the script at the repository root (it syncs and builds the primary checkout):

```
scripts/ios-build.sh device       # Release build on the iPhone connected by cable
scripts/ios-build.sh testflight   # archive and upload; the build number is the commit count of main
```

Signing uses the Apple ID signed into Xcode. Bump `MARKETING_VERSION` in `project.yml` for a new version.
`ExportOptions.plist` uses `method` `app-store-connect` and `destination` `upload`. `PrivacyInfo.xcprivacy` in each
target declares the App Group defaults; the app's also declares the anonymous analytics (product interaction, other
diagnostic data, a random install id and coarse location; not linked, not tracking). Keep it in step with the App
Store privacy answers.
