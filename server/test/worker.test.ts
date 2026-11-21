// The deployed shape: requests through the Worker's fetch handler, with the site's assets and the local D1.
import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { makeChain, sign, validBody, yearly } from "./fixtures.ts";

const endpoint = "https://snuffle.ai/api/v1/draft-reply";

function post(body: unknown) {
  return SELF.fetch(endpoint, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function xcodeProof(overrides: Record<string, unknown> = {}) {
  // Local StoreKit testing signs this way; the test Worker accepts it, production does not.
  return sign({ ...yearly, environment: "Xcode", ...overrides }, await makeChain(false));
}

beforeEach(async () => {
  await env.DB.batch([
    env.DB.prepare("DELETE FROM draft_requests"),
    env.DB.prepare("DELETE FROM daily_spend"),
    env.DB.prepare("DELETE FROM purchase_installs"),
    env.DB.prepare("DELETE FROM purchases"),
    env.DB.prepare("DELETE FROM model_config"),
  ]);
});

describe("site", () => {
  it("serves the static pages and the PostHog client metadata", async () => {
    const home = await SELF.fetch("https://snuffle.ai/");
    expect(home.status).toBe(200);
    expect(await home.text()).toContain("Snuffle");

    const client = await SELF.fetch("https://snuffle.ai/oauth/posthog-client.json");
    expect(client.status).toBe(200);
    expect((await client.json<{ client_id: string }>()).client_id).toBe("https://snuffle.ai/oauth/posthog-client.json");

    expect((await SELF.fetch("https://snuffle.ai/no-such-page")).status).toBe(404);
  });

  it("answers unknown API paths with JSON", async () => {
    const response = await SELF.fetch("https://snuffle.ai/api/v2/anything");
    expect(response.status).toBe(404);
    expect(await response.json()).toMatchObject({ code: "not_found" });
  });
});

describe("drafting API", () => {
  it("refuses requests without a valid Pro proof before touching the model", async () => {
    expect((await post({ ...validBody, entitlement: null })).status).toBe(402);
    expect((await post({ ...validBody, entitlement: "not-a-jws" })).status).toBe(402);
    const expired = await xcodeProof({ expiresDate: Date.parse("2026-01-01T00:00:00Z") });
    expect((await post({ ...validBody, entitlement: expired })).status).toBe(402);
    expect((await env.DB.prepare("SELECT count(*) AS n FROM draft_requests").first<{ n: number }>())?.n).toBe(0);
  });

  it("is unavailable until a model is configured", async () => {
    const response = await post({ ...validBody, entitlement: await xcodeProof() });
    expect(response.status).toBe(503);
    // The purchase is already linked to this install.
    const linked = await env.DB.prepare("SELECT install_id FROM purchase_installs").first<{ install_id: string }>();
    expect(linked?.install_id).toBe(validBody.installId);
  });

  it("records a provider failure, books its estimate and returns the credit", async () => {
    // No SNUFFLE_ANTHROPIC_API_KEY in tests, so the call fails after admission.
    await env.DB.prepare(
      `INSERT INTO model_config (provider, model, input_usd_per_mtok, output_usd_per_mtok, active)
       VALUES ('anthropic', 'claude-test', 1, 5, 1)`,
    ).run();
    const response = await post({ ...validBody, entitlement: await xcodeProof() });
    expect(response.status).toBe(502);
    expect(await response.json()).toMatchObject({ code: "draft_failed" });

    const row = await env.DB.prepare("SELECT status, error, cost_usd, original_transaction_id FROM draft_requests")
      .first<{ status: string; error: string; cost_usd: number; original_transaction_id: string }>();
    expect(row).toMatchObject({ status: "failed", original_transaction_id: "2000000123" });
    expect(row?.error).toContain("SNUFFLE_ANTHROPIC_API_KEY is not set");
    const spend = await env.DB.prepare("SELECT cost_usd, reserved_usd FROM daily_spend").first<
      { cost_usd: number; reserved_usd: number }
    >();
    expect(spend?.reserved_usd).toBe(0);
    expect(spend?.cost_usd).toBe(row?.cost_usd);

    // The same request id again is a duplicate, not a second charge.
    expect((await post({ ...validBody, entitlement: await xcodeProof() })).status).toBe(409);
  });
});
