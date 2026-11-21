// Production wiring for the draft handler: D1 for bookkeeping, the configured model provider, and an optional
// Langfuse export of trace metadata.
import type { DraftDeps, EntitlementCheck } from "./draft-handler.ts";
import { complete, keyName, ProviderError } from "./models.ts";
import { Store } from "./store.ts";
import { grantsPro, verifySignedTransaction } from "./storekit.ts";

const BUNDLE_ID = "ai.snuffle.app";

/** Secrets set with `wrangler secret put`; only the active provider's key is needed. */
export interface Secrets {
  SNUFFLE_OPENAI_API_KEY?: string;
  SNUFFLE_ANTHROPIC_API_KEY?: string;
  SNUFFLE_DEEPSEEK_API_KEY?: string;
  SNUFFLE_DASHSCOPE_API_KEY?: string;
  SNUFFLE_OPENROUTER_API_KEY?: string;
  LANGFUSE_BASE_URL?: string;
  LANGFUSE_PUBLIC_KEY?: string;
  LANGFUSE_SECRET_KEY?: string;
}

export type AppEnv = Env & Secrets;

export function liveDeps(env: AppEnv, ctx: ExecutionContext): DraftDeps {
  const store = new Store(env.DB);
  const allowXcode = env.SNUFFLE_ALLOW_XCODE_TRANSACTIONS === "true";

  return {
    async checkEntitlement(jws, installId): Promise<EntitlementCheck> {
      const now = new Date();
      let transaction;
      try {
        transaction = await verifySignedTransaction(jws, { bundleId: BUNDLE_ID, now, allowXcode });
      } catch {
        return { status: "invalid" };
      }
      if (!grantsPro(transaction, now)) return { status: "expired" };
      const linked = await store.linkPurchase(transaction, installId);
      return linked === "ok" ? { status: "ok", purchaseId: transaction.originalTransactionId } : { status: "shared" };
    },

    activeModel: () => store.activeModel(),
    admit: (input) => store.admit(input),

    async finish(requestId, status, usage) {
      try {
        await store.finish(requestId, status, usage);
      } catch (error) {
        console.error(`finish ${requestId}: ${error}`);
      }
    },

    complete(config, system, user) {
      const key = env[keyName(config.provider) as keyof Secrets];
      if (!key) return Promise.reject(new ProviderError(`${keyName(config.provider)} is not set`));
      return complete(config, system, user, key);
    },

    trace: langfuseExporter(env, ctx),
    now: () => Date.now(),
  };
}

/** Sends trace metadata (never review text) to Langfuse when its keys are set. Trace id = request id without dashes. */
function langfuseExporter(env: Secrets, ctx: ExecutionContext) {
  const { LANGFUSE_BASE_URL: base, LANGFUSE_PUBLIC_KEY: publicKey, LANGFUSE_SECRET_KEY: secretKey } = env;
  if (!base || !publicKey || !secretKey) return undefined;
  return (event: Record<string, unknown>) => {
    const traceId = String(event.id).replaceAll("-", "");
    const timestamp = new Date().toISOString();
    const batch = [
      {
        id: crypto.randomUUID(),
        type: "trace-create",
        timestamp,
        body: { id: traceId, name: "draft-reply", userId: event.installId, metadata: { status: event.status } },
      },
      {
        id: crypto.randomUUID(),
        type: "generation-create",
        timestamp,
        body: {
          traceId,
          name: "draft",
          model: event.model,
          usage: { input: event.inputTokens ?? undefined, output: event.outputTokens ?? undefined, unit: "TOKENS" },
          metadata: {
            provider: event.provider,
            costUsd: event.costUsd,
            latencyMs: event.latencyMs,
            platform: event.platform,
            rating: event.rating,
            error: event.error,
          },
          level: event.status === "failed" ? "ERROR" : "DEFAULT",
        },
      },
    ];
    // Finishes after the response is sent.
    ctx.waitUntil(
      fetch(`${base.replace(/\/$/, "")}/api/public/ingestion`, {
        method: "POST",
        headers: { "content-type": "application/json", authorization: `Basic ${btoa(`${publicKey}:${secretKey}`)}` },
        body: JSON.stringify({ batch }),
      }).then(() => undefined, (error) => console.error(`langfuse: ${error}`)),
    );
  };
}
