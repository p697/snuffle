# Snuffle

An iPhone app for indie developers and founders: one big refresh button that pulls new users, revenue and store reviews for every product you run, across PostHog, RevenueCat, App Store Connect and Google Play.

## Layout

- `ios/` — the iPhone app, its widgets and tests (SwiftUI, generated with XcodeGen).
- `server/` — the Cloudflare Worker on snuffle.ai: serves `site/` and drafts review replies, with a D1 database.
- `site/` — the static pages it serves (home, privacy policy, terms, OAuth client metadata).

Each folder has its own README with the commands to build, test and deploy it.

## Privacy by design

The accounts you connect and the data they return stay on your iPhone: the app talks to each platform directly.
The server only sees a review you ask it to draft a reply for, and never stores its text. See `server/README.md`.

## License

The code is MIT licensed (see `LICENSE`). The Snuffle name and icon are not covered by the license; please use your
own if you ship a fork.

