# Snuffle server

One Cloudflare Worker (`snuffle`) on snuffle.ai. It serves the static site in `../site/public` and, under `/api`,
drafts review replies. The app reads every platform directly from the phone, so no user credentials or metrics
ever reach the server. Bookkeeping lives in a D1 database (`snuffle`).

## What runs

`POST /api/v1/draft-reply`, called by the app with a random install id (kept in the device's Keychain) and the
StoreKit 2 signed transaction that proves Pro. There are no accounts.

1. Verifies the signed transaction (chain to Apple Root CA - G3, Apple marker extensions, signature, bundle id) and
   that it grants Pro. One purchase may be used by at most `max_installs_per_purchase` installs.
2. Admits the request with one conditional insert: idempotent per request id, at most `daily_install_credits`
   drafts per install per UTC day (never shown in the app), and a global `daily_usd_ceiling`. D1 runs a batch as a
   transaction, one at a time, so parallel requests cannot both slip under a limit.
3. Calls the active model in `model_config` (no provider fallback) and settles the real cost. Triggers on
   `draft_requests` keep `daily_spend` in step. A failed draft returns the install's credit; its cost still counts
   against the ceiling.

Review text is never stored. `draft_requests` keeps one row per request with its shape (store, rating, language,
length), model, tokens, cost, latency and error: it is both the usage ledger and the trace. Langfuse export of the
same metadata is optional.

| Path | Contents |
| --- | --- |
| `src/index.ts` | Routing: `/api/*` here, everything else from static assets. |
| `src/draft-handler.ts` | The request flow, with injected dependencies. |
| `src/store.ts` | D1 reads and writes. |
| `src/storekit.ts` | Signed transaction verification. |
| `src/models.ts`, `src/prompt.ts`, `src/request.ts` | Providers, the prompt and input validation. |
| `migrations/` | D1 schema, triggers and operator views. |

## Secrets

Set with `npx wrangler secret put <NAME>`, one dedicated Snuffle key per provider:

| Name | Purpose |
| --- | --- |
| `SNUFFLE_OPENAI_API_KEY`, `SNUFFLE_ANTHROPIC_API_KEY`, `SNUFFLE_DEEPSEEK_API_KEY`, `SNUFFLE_DASHSCOPE_API_KEY`, `SNUFFLE_OPENROUTER_API_KEY` | Only the active provider's key is needed. |
| `LANGFUSE_BASE_URL`, `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` | Optional trace export (metadata only). |

`SNUFFLE_ALLOW_XCODE_TRANSACTIONS` is a plain variable, `"false"` in `wrangler.jsonc`. Only local runs and tests set
it to `"true"` to accept Xcode StoreKit test purchases.

## Operating it

```bash
# Switch model: add a revision, then make it the only active one.
npx wrangler d1 execute snuffle --remote --command "INSERT INTO model_config
  (provider, model, max_output_tokens, temperature, input_usd_per_mtok, output_usd_per_mtok)
  VALUES ('deepseek', 'deepseek-chat', 700, 0.6, 0.27, 1.10)"
npx wrangler d1 execute snuffle --remote --command "UPDATE model_config SET active = (revision = <new revision>)"

# Limits.
npx wrangler d1 execute snuffle --remote --command "UPDATE app_config SET value = 10 WHERE key = 'daily_usd_ceiling'"

# Usage.
npx wrangler d1 execute snuffle --remote --command "SELECT * FROM usage_by_day LIMIT 14"
npx wrangler d1 execute snuffle --remote --command "SELECT * FROM usage_by_install_today LIMIT 20"
```

## Develop

```bash
cd server
pnpm install
pnpm typecheck
pnpm test            # vitest in the Workers runtime, with a local D1 and the real migration
```

Run it locally against the app (Local.xcconfig: `SNUFFLE_API_URL = http:/$()/127.0.0.1:8787`):

```bash
npx wrangler d1 migrations apply snuffle --local
npx wrangler dev --ip 127.0.0.1 --port 8787 --var SNUFFLE_ALLOW_XCODE_TRANSACTIONS:true
```

Deploys go through CI (`.github/workflows/deploy.yml`) on merge to `main`: D1 migrations first, then the Worker.
