// POST /api/v1/draft-reply: check Pro, admit against hidden credits and the spend ceiling, call the model, settle
// the cost. Dependencies are injected so the flow runs in tests with a local D1 and no provider.
import { buildMessages, parseDraft } from "./prompt.ts";
import { InvalidRequest, parseDraftRequest } from "./request.ts";
import { type Completion, costUsd, estimateUsd, type ModelConfig } from "./models.ts";
import type { Admission, AdmitInput, Settlement } from "./store.ts";

export type EntitlementCheck = { status: "ok"; purchaseId: string } | { status: "expired" | "invalid" | "shared" };

export interface DraftDeps {
  checkEntitlement(jws: string, installId: string): Promise<EntitlementCheck>;
  activeModel(): Promise<ModelConfig | null>;
  admit(input: AdmitInput): Promise<Admission>;
  finish(requestId: string, status: "succeeded" | "failed", usage: Settlement): Promise<void>;
  complete(config: ModelConfig, system: string, user: string): Promise<Completion>;
  /** Optional trace export (metadata only); failures are ignored. */
  trace?(event: Record<string, unknown>): void;
  now(): number;
}

export function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

export function fail(status: number, code: string, message: string): Response {
  return json(status, { code, message });
}

export async function handleDraft(request: Request, deps: DraftDeps): Promise<Response> {
  if (request.method !== "POST") return fail(405, "method", "POST only");

  let draftRequest;
  try {
    draftRequest = parseDraftRequest(await request.json());
  } catch (error) {
    return fail(400, "invalid", error instanceof InvalidRequest ? error.message : "body is not JSON");
  }
  const { requestId, installId, review } = draftRequest;

  if (!draftRequest.entitlement) return fail(402, "pro_required", "起草回复是 Pro 功能");
  const entitlement = await deps.checkEntitlement(draftRequest.entitlement, installId);
  if (entitlement.status !== "ok") {
    const message = entitlement.status === "shared" ? "这笔购买已经在太多设备上使用" : "没有有效的 Pro 订阅";
    return fail(402, "pro_required", message);
  }

  const model = await deps.activeModel();
  if (!model) return fail(503, "unavailable", "起草服务暂时不可用");

  const { system, user: prompt } = buildMessages(draftRequest);
  const estimate = estimateUsd(model, system.length + prompt.length);
  const admission = await deps.admit({
    requestId,
    installId,
    purchaseId: entitlement.purchaseId,
    day: new Date(deps.now()).toISOString().slice(0, 10),
    estimateUsd: estimate,
    model,
    review: { platform: review.platform, rating: review.rating, language: review.language, chars: review.body.length },
  });
  switch (admission) {
    case "ok":
      break;
    case "duplicate":
    case "conflict":
      return fail(409, "duplicate", "这个请求已经处理过");
    case "install_limit":
      return fail(429, "limit", "今天起草得太多了，明天再来");
    case "budget":
      return fail(503, "unavailable", "起草服务暂时不可用，请稍后再试");
  }

  const started = deps.now();
  let completion: Completion | null = null;
  try {
    completion = await deps.complete(model, system, prompt);
    const draft = parseDraft(completion.text, review.platform);
    const cost = costUsd(model, completion.inputTokens, completion.outputTokens, estimate);
    const latencyMs = deps.now() - started;
    await deps.finish(requestId, "succeeded", {
      input: completion.inputTokens,
      output: completion.outputTokens,
      costUsd: cost,
      latencyMs,
      error: null,
    });
    deps.trace?.({
      id: requestId,
      installId,
      status: "succeeded",
      model: model.model,
      provider: model.provider,
      inputTokens: completion.inputTokens,
      outputTokens: completion.outputTokens,
      costUsd: cost,
      latencyMs,
      platform: review.platform,
      rating: review.rating,
    });
    return json(200, draft);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    // A failed call may still be billed by the provider: book what usage we know, or the estimate.
    const cost = completion ? costUsd(model, completion.inputTokens, completion.outputTokens, estimate) : estimate;
    await deps.finish(requestId, "failed", {
      input: completion?.inputTokens ?? null,
      output: completion?.outputTokens ?? null,
      costUsd: cost,
      latencyMs: deps.now() - started,
      error: message,
    });
    deps.trace?.({ id: requestId, installId, status: "failed", model: model.model, error: message });
    return fail(502, "draft_failed", "这次没能起草出来，请再试一次");
  }
}
