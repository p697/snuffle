# Analytics (PostHog)

Snuffle's own usage analytics: anonymous, per install, in the dedicated PostHog organization and project "Snuffle" (US cloud,
UTC). The project is named in `Config/Shared.xcconfig` by its client token, which is write-only and public by design.
This file is the source of truth for events and metrics; change it together with `Snuffle/App/Analytics.swift`.

## Rules

- Business code calls the typed methods of `Analytics`; nothing else imports `PostHog`.
- Track decisions and outcomes: an entry into a flow, a committed change, an attempt and how it ended. A tap is not a
  success. No automatic lifecycle, screen, element, replay or feature-flag capture; no capture in `body`.
- Payloads are small enums, booleans and counts. Never names, emails, account or project ids, keys, tokens, URLs,
  numbers read from a connected source, review or reply text, or error messages (`FailureKind` is the error).
- Identity is the SDK's anonymous install id. `identify` is never called and no person profiles are processed, so an
  "install" is the unit: a reinstall is a new install.
- Analytics never blocks the app: the SDK queues and retries on its own, and an empty token turns it off.
- Unit tests (the app hosts them) and UI tests (`-noAnalytics`) never start the SDK. Never send synthetic events to
  make a chart look populated.

## Context on every event

| Property | Values |
| --- | --- |
| `client_app` | `snuffle_ios` |
| `analytics_schema_version` | `1`; bump when an event's meaning changes |
| `app_environment` | `development` (Debug, or signed with a provisioning profile, like the owner's device builds) or `release` (TestFlight and App Store) |
| `is_pro`, `demo_mode` | booleans; `is_pro` is missing until the first entitlement check of a fresh install finishes |
| `project_count` | the person's own projects (0 in demo mode until they add one) |
| `widget_count` | Snuffle widgets on the home and lock screens, updated on each `app_opened` |

The SDK adds `$app_version`, `$app_build`, `$os_version`, `$is_testflight`, `$is_emulator` and GeoIP location.

Business charts use `client_app = 'snuffle_ios' AND app_environment = 'release' AND $is_testflight = false`.

## Events

| Event | When | Properties |
| --- | --- | --- |
| `app_opened` | The app becomes active (launch or back from the background) | — |
| `tab_viewed` | The person switches tab | `tab`: today, money, reviews, projects |
| `demo_mode_changed` | Demo mode turned on or off, from anywhere | `enabled` |
| `add_project_opened` | The add-project flow opens | `source`: welcome, home, projects, key_file (a `.p8` opened in Snuffle) |
| `source_connect_resolved` | A sign-in or key check against a platform ends, or an App Store app found without a key is picked (or its search fails) | `platform`, `method` (oauth, key, search, saved), `flow` (new_project, existing_project), `outcome` (succeeded, failed, cancelled), `error_kind` on failure |
| `project_saved` | A project is created or edited | `is_new`, `source_count`, `has_posthog`, `has_revenuecat`, `has_app_store`, `has_google_play`, `project_count`, `excluded_surfaces` (the kinds of traffic left out of people numbers: `ios`, `android`, `web`, `visitors`, `other`; empty without PostHog) |
| `project_deleted` | A project is deleted | `source_count`, `project_count` |
| `card_layout_saved` | "完成" in the card editor | `big`, `small` (metric kinds in order, rows one after another, e.g. `total_users`, `active_week`, `installs`; any other event is `event`, never its name), `rows` (how many small numbers each row holds, e.g. `[3, 2]`), `trend` (14-day bars shown), `split` (platform split shown), `everywhere` (applied to every project), `dragged` (a number was moved by dragging) |
| `counting_changed` | A project's people counting changes: read from a PostHog dashboard (also automatically when a project is added), edited by hand, or set back to Snuffle's own | `source` (dashboard, manual, standard), `has_activity_event`, `condition_count`, `unit` (person, install), `has_platform_property`, `has_since`. Never the event, the conditions, the property or the dashboard |
| `charts_pinned` | Charts from a PostHog dashboard are placed on a project's board | `added`, `total` (counts only, never chart names) |
| `account_removed` | A platform account is removed | `platform` |
| `refresh_completed` | A refresh finishes revealing every card | `trigger` (manual, open, project, connect, retry), `projects`, `failed_projects`, `went_up`, `sale`, `duration_ms` |
| `refresh_source_failed` | One source could not be read in a refresh (one per source per refresh) | `platform`, `error_kind` |
| `paywall_viewed` | The paywall opens | `reason`: projects, history, drafts, widgets, general |
| `purchase_resolved` | The purchase sheet ends | `plan` (monthly, yearly, lifetime), `reason`, `trial`, `outcome` (purchased, pending, cancelled, failed) |
| `restore_resolved` | "恢复购买" finishes | `source` (paywall, settings), `outcome` (restored, not_found) |
| `review_reply_resolved` | A reply is published or fails | `platform`, `outcome`, `error_kind` on failure |

`platform` is `posthog`, `revenuecat`, `app_store` or `google_play`. `error_kind` is a `FailureKind`:
`unauthorized`, `forbidden`, `rate_limited`, `client_error`, `server_error`, `network`, `invalid_response`,
`invalid_key`, `missing_credential` or `other`.

## Metrics

| Metric | Definition |
| --- | --- |
| DAU / WAU / MAU | Unique installs with `app_opened` in the UTC day / last 7 / last 30 days. Never sum DAU. |
| New installs | Installs by the date of their first `app_opened`; not App Store downloads (those are in App Store Connect). |
| Activation | Within 24 h of the first `app_opened`: `source_connect_resolved` succeeded → `project_saved` with `is_new` → `refresh_completed` with `failed_projects = 0`. |
| Demo first | Share of new installs whose first flow is `demo_mode_changed` enabled with `project_count = 0`. |
| Connect success | `source_connect_resolved` by `platform` and `method`: succeeded / (succeeded + failed); cancellations apart. |
| Refresh health | `refresh_source_failed` per `refresh_completed`, by `platform` and `error_kind`; `unauthorized` means a person must reconnect. |
| Engagement | `refresh_completed` per active install per day, by `trigger`; `tab_viewed` by `tab`; installs with `widget_count > 0`. |
| Metric demand | Installs with `card_layout_saved`; which kinds appear in `big` and `small`, how many use a second row, how often `trend` and `split` are turned off, to choose the defaults; `dragged` shows whether dragging is found. |
| Counting trust | Share of PostHog projects with `counting_changed` from `dashboard` (read automatically or chosen) versus left on Snuffle's own; `charts_pinned` per project with a board. |
| Paywall conversion | Installs with `purchase_resolved` purchased / installs with `paywall_viewed`, by `reason` and `plan`. |
| Retention | D1 / D7 / D30 return with `app_opened` after the first `app_opened`; hide periods not yet complete. |

`purchase_resolved` is what the phone saw. Revenue, trials converting, renewals and refunds come from App Store
Connect; do not compute them from these events.

## Budget

The organization is on the Free plan: 1,000,000 events a month, after which PostHog drops data rather than charging.
A typical active install sends about 10–20 events a day (a few opens and refreshes, some tab switches), so the
allowance covers roughly 1,500–3,000 daily active installs. Check usage on the organization's billing page after each
release; before 700K events in a cycle, cut `tab_viewed` first. Never add a payment method without the owner.

## Changing events

1. Name the question first and reuse an event when one fits.
2. Change `Analytics.swift`, the call sites and this file together; keep the payload rules above.
3. Check real ingestion: run a Debug build on the simulator, then query the project for the new event with
   `app_environment = 'development'`. A build that compiles is not proof that the event arrives.
4. Update affected insights in PostHog.
