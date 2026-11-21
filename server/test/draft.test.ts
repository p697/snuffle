import { describe, expect, it } from "vitest";
import { type DraftDeps, handleDraft } from "../src/draft-handler.ts";
import { complete, costUsd, estimateUsd } from "../src/models.ts";
import { buildMessages, parseDraft, UnusableDraft } from "../src/prompt.ts";
import { InvalidRequest, parseDraftRequest } from "../src/request.ts";
import type { AdmitInput, Settlement } from "../src/store.ts";
import { model, validBody } from "./fixtures.ts";


function request(body: unknown): Request {
  return new Request("https://snuffle.test/api/v1/draft-reply", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

function fakeDeps(overrides: Partial<DraftDeps> = {}) {
  const finished: ({ status: string } & Settlement)[] = [];
  const admitted: AdmitInput[] = [];
  let clock = Date.parse("2026-11-21T08:00:00Z");
  const deps: DraftDeps = {
    checkEntitlement: () => Promise.resolve({ status: "ok", purchaseId: "2000000123" }),
    activeModel: () => Promise.resolve(model),
    admit: (input) => {
      admitted.push(input);
      return Promise.resolve("ok");
    },
    finish: (_id, status, usage) => {
      finished.push({ status, ...usage });
      return Promise.resolve();
    },
    complete: () =>
      Promise.resolve({
        text:
          '```json\n{"reply":"Sorry about the crash, a fix ships this week.","translation":"抱歉闪退了。","language":"en"}\n```',
        inputTokens: 400,
        outputTokens: 60,
      }),
    now: () => (clock += 250),
    ...overrides,
  };
  return { deps, finished, admitted };
}

describe("request validation", () => {
  it("rejects what the model should never see", () => {
    expect(parseDraftRequest(validBody).review.platform).toBe("googlePlay");
    const bad = (body: unknown, message?: RegExp) =>
      expect(() => parseDraftRequest(body)).toThrow(message ?? InvalidRequest);
    bad({ ...validBody, requestId: "nope" }, /requestId must be a UUID/);
    bad({ ...validBody, installId: undefined }, /installId is required/);
    bad({ ...validBody, installId: "device-1" }, /installId must be a UUID/);
    bad({ ...validBody, tone: "angry" }, /tone/);
    bad({ ...validBody, review: { ...validBody.review, rating: 6 } });
    bad({ ...validBody, review: { ...validBody.review, body: "x".repeat(6_001) } }, /longer/);
    bad({ ...validBody, review: { ...validBody.review, body: "  " } });
  });
});

describe("prompt and parsing", () => {
  it("keeps the review as data and states the store's limit", () => {
    const { system, user } = buildMessages(parseDraftRequest(validBody));
    expect(system).toContain("At most 350 characters");
    expect(system).toContain("untrusted text");
    expect(system).toContain("sign-off: Mia");
    expect(JSON.parse(user).review).toBe("Crashes when I attach a PDF");
  });

  it("tolerates fences and enforces the limit", () => {
    expect(parseDraft('Sure!\n{"reply":"Thanks!","translation":"谢谢！","language":"en"}', "appStore").reply)
      .toBe("Thanks!");
    const long = parseDraft(JSON.stringify({ reply: "a".repeat(500), translation: "", language: "en" }), "googlePlay");
    expect([...long.reply].length).toBe(350);
    expect(long.reply.endsWith("…")).toBe(true);
    expect(() => parseDraft('{"reply":""}', "appStore")).toThrow(UnusableDraft);
    expect(() => parseDraft("no json here", "appStore")).toThrow(UnusableDraft);
  });
});

describe("models", () => {
  it("costs come from usage, and unknown usage costs the estimate", () => {
    expect(costUsd(model, 1_000_000, 0, 9)).toBe(0.27);
    expect(costUsd(model, null, 10, 9)).toBe(9);
    expect(estimateUsd(model, 2_000)).toBeGreaterThan(costUsd(model, 1_300, 700, 0) - 1e-9);
  });

  it("sends OpenAI-compatible and Anthropic requests in the right shape", async () => {
    const calls: { url: string; body: Record<string, unknown>; headers: Headers }[] = [];
    const fake = (url: string | URL | Request, init?: RequestInit) => {
      calls.push({ url: String(url), body: JSON.parse(String(init?.body)), headers: new Headers(init?.headers) });
      const anthropic = String(url).includes("anthropic");
      return Promise.resolve(
        Response.json(
          anthropic
            ? { content: [{ type: "text", text: '{"reply":"hi"}' }], usage: { input_tokens: 10, output_tokens: 5 } }
            : { choices: [{ message: { content: '{"reply":"hi"}' } }], usage: { prompt_tokens: 10, completion_tokens: 5 } },
        ),
      );
    };
    const deepseek = await complete(model, "sys", "user", "key-1", fake as typeof fetch);
    expect(deepseek).toEqual({ text: '{"reply":"hi"}', inputTokens: 10, outputTokens: 5 });
    expect(calls[0].url).toBe("https://api.deepseek.com/chat/completions");
    expect(calls[0].body.max_tokens).toBe(700);
    expect(calls[0].headers.get("authorization")).toBe("Bearer key-1");

    await complete({ ...model, provider: "openai", model: "gpt-x", temperature: null }, "s", "u", "k", fake as typeof fetch);
    expect(calls[1].body.max_completion_tokens).toBe(700);
    expect("temperature" in calls[1].body).toBe(false);

    const claude = await complete({ ...model, provider: "anthropic", model: "claude" }, "sys", "u", "k2", fake as typeof fetch);
    expect(claude.inputTokens).toBe(10);
    expect(calls[2].headers.get("x-api-key")).toBe("k2");
    expect(calls[2].body.system).toBe("sys");

    const failing = () => Promise.resolve(new Response("overloaded", { status: 529 }));
    await expect(complete(model, "s", "u", "k", failing as typeof fetch)).rejects.toThrow(/529/);
  });
});

describe("draft handler", () => {
  it("admits, settles and returns a full draft", async () => {
    const { deps, finished, admitted } = fakeDeps();
    const response = await handleDraft(request(validBody), deps);
    expect(response.status).toBe(200);
    expect((await response.json<{ translation: string }>()).translation).toBe("抱歉闪退了。");
    expect(admitted[0]).toMatchObject({
      installId: validBody.installId,
      purchaseId: "2000000123",
      day: "2026-11-21",
      review: { platform: "googlePlay", rating: 2, language: "en_US", chars: 27 },
    });
    expect(JSON.stringify(admitted[0])).not.toContain("Crashes"); // review text never reaches the database
    expect(finished).toHaveLength(1);
    expect(finished[0]).toMatchObject({ status: "succeeded", costUsd: (400 * 0.27 + 60 * 1.1) / 1_000_000, error: null });
  });

  it("maps each refusal to its own status", async () => {
    const status = async (body: unknown, overrides: Partial<DraftDeps> = {}) =>
      (await handleDraft(request(body), fakeDeps(overrides).deps)).status;
    expect(await status({ ...validBody, entitlement: null })).toBe(402);
    expect(await status(validBody, { checkEntitlement: () => Promise.resolve({ status: "shared" }) })).toBe(402);
    expect(await status(validBody, { checkEntitlement: () => Promise.resolve({ status: "expired" }) })).toBe(402);
    expect(await status(validBody, { admit: () => Promise.resolve("install_limit") })).toBe(429);
    expect(await status(validBody, { admit: () => Promise.resolve("budget") })).toBe(503);
    expect(await status(validBody, { admit: () => Promise.resolve("duplicate") })).toBe(409);
    expect(await status(validBody, { activeModel: () => Promise.resolve(null) })).toBe(503);
    expect(await status({ ...validBody, installId: null })).toBe(400);
    const get = new Request("https://snuffle.test/api/v1/draft-reply", { method: "GET" });
    expect((await handleDraft(get, fakeDeps().deps)).status).toBe(405);
  });

  it("books the estimate and frees the credit when the provider fails", async () => {
    const { deps, finished } = fakeDeps({ complete: () => Promise.reject(new Error("provider returned 500")) });
    expect((await handleDraft(request(validBody), deps)).status).toBe(502);
    expect(finished).toHaveLength(1);
    expect(finished[0].status).toBe("failed");
    expect(finished[0].costUsd).toBeGreaterThan(0);
    expect(finished[0].error).toContain("500");
  });

  it("counts an unusable model answer as a failure, with its real usage", async () => {
    const { deps, finished } = fakeDeps({
      complete: () => Promise.resolve({ text: "I cannot help with that.", inputTokens: 300, outputTokens: 8 }),
    });
    expect((await handleDraft(request(validBody), deps)).status).toBe(502);
    expect(finished[0].costUsd).toBe((300 * 0.27 + 8 * 1.1) / 1_000_000);
  });
});
