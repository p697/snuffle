// The bookkeeping against a real (local) D1 with the production migration applied.
import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { type AdmitInput, Store } from "../src/store.ts";
import type { SignedTransaction } from "../src/storekit.ts";
import { model } from "./fixtures.ts";

const store = new Store(env.DB);
const day = "2026-11-21";
const installA = "00000000-0000-4000-8000-00000000000a";
const installB = "00000000-0000-4000-8000-00000000000b";

let counter = 0;
function admission(overrides: Partial<AdmitInput> = {}): AdmitInput {
  counter += 1;
  return {
    requestId: `10000000-0000-4000-8000-${String(counter).padStart(12, "0")}`,
    installId: installA,
    purchaseId: "2000000123",
    day,
    estimateUsd: 0.001,
    model,
    review: { platform: "appStore", rating: 4, language: "en", chars: 120 },
    ...overrides,
  };
}

const settled = { input: 400, output: 60, costUsd: 0.0002, latencyMs: 900, error: null };

async function setConfig(key: string, value: number) {
  await env.DB.prepare("UPDATE app_config SET value = ?2 WHERE key = ?1").bind(key, value).run();
}

async function spend() {
  return await env.DB.prepare("SELECT cost_usd, reserved_usd FROM daily_spend WHERE day = ?").bind(day).first<
    { cost_usd: number; reserved_usd: number }
  >();
}

beforeEach(async () => {
  await env.DB.batch([
    env.DB.prepare("DELETE FROM draft_requests"),
    env.DB.prepare("DELETE FROM daily_spend"),
    env.DB.prepare("DELETE FROM purchase_installs"),
    env.DB.prepare("DELETE FROM purchases"),
    env.DB.prepare("DELETE FROM model_config"),
    env.DB.prepare("UPDATE app_config SET value = 5 WHERE key = 'daily_usd_ceiling'"),
    env.DB.prepare("UPDATE app_config SET value = 40 WHERE key = 'daily_install_credits'"),
    env.DB.prepare("UPDATE app_config SET value = 3 WHERE key = 'max_installs_per_purchase'"),
  ]);
});

describe("model config", () => {
  it("returns the single active revision", async () => {
    expect(await store.activeModel()).toBeNull();
    await env.DB.prepare(
      `INSERT INTO model_config (provider, model, max_output_tokens, temperature, input_usd_per_mtok, output_usd_per_mtok, extra, active)
       VALUES ('anthropic', 'old', 600, NULL, 1, 5, '{}', 0), ('deepseek', 'deepseek-chat', 700, 0.6, 0.27, 1.1, '{"top_p":0.9}', 1)`,
    ).run();
    expect(await store.activeModel()).toMatchObject({
      provider: "deepseek",
      model: "deepseek-chat",
      temperature: 0.6,
      extra: { top_p: 0.9 },
    });
    await expect(
      env.DB.prepare("INSERT INTO model_config (provider, model, input_usd_per_mtok, output_usd_per_mtok, active) VALUES ('openai', 'x', 1, 1, 1)")
        .run(),
    ).rejects.toThrow(/UNIQUE/);
  });
});

describe("admission", () => {
  it("reserves the estimate, then books the real cost once", async () => {
    const input = admission({ estimateUsd: 0.004 });
    expect(await store.admit(input)).toBe("ok");
    expect(await spend()).toEqual({ cost_usd: 0, reserved_usd: 0.004 });

    await store.finish(input.requestId, "succeeded", settled);
    expect(await spend()).toEqual({ cost_usd: 0.0002, reserved_usd: 0 });
    await store.finish(input.requestId, "failed", { ...settled, costUsd: 1 }); // a second finish changes nothing
    expect(await spend()).toEqual({ cost_usd: 0.0002, reserved_usd: 0 });

    const row = await env.DB.prepare("SELECT * FROM draft_requests WHERE request_id = ?").bind(input.requestId).first();
    expect(row).toMatchObject({ status: "succeeded", input_tokens: 400, review_platform: "appStore", review_chars: 120 });
  });

  it("is idempotent per request id and refuses another install's id", async () => {
    const input = admission();
    expect(await store.admit(input)).toBe("ok");
    expect(await store.admit(input)).toBe("duplicate");
    expect(await store.admit({ ...input, installId: installB })).toBe("conflict");
    expect((await spend())?.reserved_usd).toBe(0.001);
  });

  it("stops an install at its daily credits, and failed drafts give the credit back", async () => {
    await setConfig("daily_install_credits", 2);
    const first = admission();
    expect(await store.admit(first)).toBe("ok");
    expect(await store.admit(admission())).toBe("ok");
    expect(await store.admit(admission())).toBe("install_limit");
    expect(await store.admit(admission({ installId: installB }))).toBe("ok"); // other installs are unaffected
    expect(await store.admit(admission({ day: "2026-11-22" }))).toBe("ok"); // a new UTC day starts fresh

    await store.finish(first.requestId, "failed", { ...settled, error: "provider returned 500" });
    expect(await store.admit(admission())).toBe("ok");
  });

  it("holds the global ceiling, counting in-flight estimates and failed costs", async () => {
    await setConfig("daily_usd_ceiling", 0.01);
    const big = admission({ estimateUsd: 0.006 });
    expect(await store.admit(big)).toBe("ok");
    expect(await store.admit(admission({ installId: installB, estimateUsd: 0.006 }))).toBe("budget");

    // The provider may still bill a failed call: its cost stays booked against the ceiling.
    await store.finish(big.requestId, "failed", { ...settled, costUsd: 0.006, error: "timeout" });
    expect(await spend()).toEqual({ cost_usd: 0.006, reserved_usd: 0 });
    expect(await store.admit(admission({ installId: installB, estimateUsd: 0.005 }))).toBe("budget");
    expect(await store.admit(admission({ installId: installB, estimateUsd: 0.004 }))).toBe("ok");
  });

  it("lets only one of many parallel requests through the last credit", async () => {
    await setConfig("daily_install_credits", 1);
    const results = await Promise.all(Array.from({ length: 8 }, () => store.admit(admission())));
    expect(results.filter((result) => result === "ok")).toHaveLength(1);
    expect(results.filter((result) => result === "install_limit")).toHaveLength(7);
  });
});

describe("purchases", () => {
  const transaction: SignedTransaction = {
    originalTransactionId: "2000000123",
    transactionId: "2000000456",
    productId: "ai.snuffle.pro.yearly",
    bundleId: "ai.snuffle.app",
    environment: "Production",
    purchaseDate: new Date("2026-11-01T00:00:00Z"),
    expiresDate: new Date("2027-11-01T00:00:00Z"),
    revocationDate: null,
  };

  it("links up to the allowed number of installs per purchase", async () => {
    await setConfig("max_installs_per_purchase", 2);
    expect(await store.linkPurchase(transaction, installA)).toBe("ok");
    expect(await store.linkPurchase(transaction, installA)).toBe("ok");
    expect(await store.linkPurchase(transaction, installB)).toBe("ok");
    expect(await store.linkPurchase(transaction, "00000000-0000-4000-8000-00000000000c")).toBe("shared");
    expect(await store.linkPurchase(transaction, installB)).toBe("ok"); // linked installs keep working

    const renewed = { ...transaction, expiresDate: new Date("2028-11-01T00:00:00Z") };
    await store.linkPurchase(renewed, installA);
    const row = await env.DB.prepare("SELECT expires_at FROM purchases WHERE original_transaction_id = ?")
      .bind(transaction.originalTransactionId).first<{ expires_at: string }>();
    expect(row?.expires_at).toBe("2028-11-01T00:00:00.000Z");
  });
});

describe("operator views", () => {
  it("summarise usage by day without review text", async () => {
    const input = admission();
    await store.admit(input);
    await store.finish(input.requestId, "succeeded", settled);
    const row = await env.DB.prepare("SELECT * FROM usage_by_day WHERE day = ?").bind(day).first();
    expect(row).toMatchObject({ drafts: 1, failures: 0, installs: 1, input_tokens: 400, cost_usd: 0.0002 });
  });
});
