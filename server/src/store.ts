// Bookkeeping in D1. D1 runs one statement at a time per database and each batch as a transaction, so every
// decision below is a single conditional write: two parallel requests cannot both slip under a limit.
import type { ModelConfig, Provider } from "./models.ts";
import type { SignedTransaction } from "./storekit.ts";

export type Admission = "ok" | "duplicate" | "conflict" | "install_limit" | "budget";

export interface AdmitInput {
  requestId: string;
  installId: string;
  purchaseId: string;
  day: string;
  estimateUsd: number;
  model: ModelConfig;
  review: { platform: string; rating: number; language: string | null; chars: number };
}

export interface Settlement {
  input: number | null;
  output: number | null;
  costUsd: number;
  latencyMs: number;
  error: string | null;
}

export class Store {
  constructor(private readonly db: D1Database) {}

  async activeModel(): Promise<ModelConfig | null> {
    const row = await this.db.prepare("SELECT * FROM model_config WHERE active = 1").first<Record<string, unknown>>();
    if (!row) return null;
    return {
      revision: Number(row.revision),
      provider: row.provider as Provider,
      model: String(row.model),
      max_output_tokens: Number(row.max_output_tokens),
      temperature: row.temperature === null ? null : Number(row.temperature),
      input_usd_per_mtok: Number(row.input_usd_per_mtok),
      output_usd_per_mtok: Number(row.output_usd_per_mtok),
      extra: JSON.parse(String(row.extra ?? "{}")),
    };
  }

  /** Records a verified purchase and links it to the presenting install, unless too many installs share it. */
  async linkPurchase(transaction: SignedTransaction, installId: string): Promise<"ok" | "shared"> {
    const id = transaction.originalTransactionId;
    const [, , linked] = await this.db.batch([
      this.db.prepare(
        `INSERT INTO purchases (original_transaction_id, product_id, environment, expires_at, revoked_at)
         VALUES (?1, ?2, ?3, ?4, ?5)
         ON CONFLICT (original_transaction_id) DO UPDATE
            SET product_id = excluded.product_id,
                expires_at = excluded.expires_at,
                revoked_at = excluded.revoked_at,
                last_verified_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')`,
      ).bind(
        id,
        transaction.productId,
        transaction.environment,
        transaction.expiresDate?.toISOString() ?? null,
        transaction.revocationDate?.toISOString() ?? null,
      ),
      this.db.prepare(
        `INSERT INTO purchase_installs (original_transaction_id, install_id)
         SELECT ?1, ?2
          WHERE (SELECT count(*) FROM purchase_installs WHERE original_transaction_id = ?1)
                < (SELECT value FROM app_config WHERE key = 'max_installs_per_purchase')
         ON CONFLICT DO NOTHING`,
      ).bind(id, installId),
      this.db.prepare("SELECT 1 AS linked FROM purchase_installs WHERE original_transaction_id = ?1 AND install_id = ?2")
        .bind(id, installId),
    ]);
    return linked.results.length > 0 ? "ok" : "shared";
  }

  /** Admits a request or says why not: idempotent per request id, within the install's credits and the ceiling. */
  async admit(input: AdmitInput): Promise<Admission> {
    const [, inserted, after] = await this.db.batch([
      this.db.prepare("INSERT INTO daily_spend (day) VALUES (?1) ON CONFLICT (day) DO NOTHING").bind(input.day),
      this.db.prepare(
        `INSERT INTO draft_requests (
           request_id, install_id, original_transaction_id, day, estimate_usd, model_revision, provider, model,
           review_platform, review_rating, review_language, review_chars)
         SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12
          WHERE NOT EXISTS (SELECT 1 FROM draft_requests WHERE request_id = ?1)
            AND (SELECT coalesce(sum(credits), 0) FROM draft_requests
                  WHERE install_id = ?2 AND day = ?4 AND status <> 'failed')
                < (SELECT value FROM app_config WHERE key = 'daily_install_credits')
            AND (SELECT cost_usd + reserved_usd FROM daily_spend WHERE day = ?4) + ?5
                <= (SELECT value FROM app_config WHERE key = 'daily_usd_ceiling')
         RETURNING request_id`,
      ).bind(
        input.requestId,
        input.installId,
        input.purchaseId,
        input.day,
        input.estimateUsd,
        input.model.revision,
        input.model.provider,
        input.model.model,
        input.review.platform,
        input.review.rating,
        input.review.language,
        input.review.chars,
      ),
      // Read in the same transaction, so a refusal is explained by the state that caused it.
      this.db.prepare(
        `SELECT (SELECT install_id FROM draft_requests WHERE request_id = ?1) AS owner,
                (SELECT coalesce(sum(credits), 0) FROM draft_requests
                  WHERE install_id = ?2 AND day = ?3 AND status <> 'failed') AS used,
                (SELECT value FROM app_config WHERE key = 'daily_install_credits') AS credit_limit`,
      ).bind(input.requestId, input.installId, input.day),
    ]);
    // RETURNING, not meta.changes: D1 counts the spend trigger's write in `changes` too.
    if (inserted.results.length === 1) return "ok";
    const state = after.results[0] as { owner: string | null; used: number; credit_limit: number };
    if (state.owner !== null) return state.owner === input.installId ? "duplicate" : "conflict";
    if (state.used >= state.credit_limit) return "install_limit";
    return "budget";
  }

  /** Completes a reserved request once; the settle trigger moves its estimate to real cost. */
  async finish(requestId: string, status: "succeeded" | "failed", usage: Settlement): Promise<void> {
    await this.db.prepare(
      `UPDATE draft_requests
          SET status = ?2, input_tokens = ?3, output_tokens = ?4, cost_usd = ?5, latency_ms = ?6,
              error = substr(?7, 1, 500), finished_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
        WHERE request_id = ?1 AND status = 'reserved'`,
    ).bind(requestId, status, usage.input, usage.output, usage.costUsd, usage.latencyMs, usage.error).run();
  }
}
