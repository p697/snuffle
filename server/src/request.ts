// What the app sends to draft a reply, checked field by field. Anything unexpected is a 400, never a model call.

export type Tone = "warm" | "professional" | "brief";
export type Store = "appStore" | "googlePlay";

export interface DraftRequest {
  requestId: string;
  /** A random id the app keeps in this device's Keychain; credits and purchase sharing are counted per install. */
  installId: string;
  appName: string;
  tone: Tone;
  signature: string;
  entitlement: string | null;
  review: {
    platform: Store;
    rating: number;
    title: string | null;
    body: string;
    author: string | null;
    territory: string | null;
    language: string | null;
  };
}

export class InvalidRequest extends Error {}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function text(value: unknown, field: string, max: number, required = false): string | null {
  if (value === undefined || value === null || value === "") {
    if (required) throw new InvalidRequest(`${field} is required`);
    return null;
  }
  if (typeof value !== "string") throw new InvalidRequest(`${field} must be a string`);
  const trimmed = value.trim();
  if (trimmed.length > max) throw new InvalidRequest(`${field} is longer than ${max} characters`);
  if (required && trimmed.length === 0) throw new InvalidRequest(`${field} is required`);
  return trimmed.length === 0 ? null : trimmed;
}

export function parseDraftRequest(input: unknown): DraftRequest {
  if (typeof input !== "object" || input === null) throw new InvalidRequest("body must be a JSON object");
  const body = input as Record<string, unknown>;
  const review = body.review as Record<string, unknown> | undefined;
  if (typeof review !== "object" || review === null) throw new InvalidRequest("review is required");

  const requestId = text(body.requestId, "requestId", 36, true)!;
  if (!UUID.test(requestId)) throw new InvalidRequest("requestId must be a UUID");
  const installId = text(body.installId, "installId", 36, true)!;
  if (!UUID.test(installId)) throw new InvalidRequest("installId must be a UUID");

  const tone = text(body.tone, "tone", 20) ?? "warm";
  if (tone !== "warm" && tone !== "professional" && tone !== "brief") {
    throw new InvalidRequest("tone is not recognised");
  }

  const platform = text(review.platform, "review.platform", 20, true);
  if (platform !== "appStore" && platform !== "googlePlay") throw new InvalidRequest("review.platform is not a store");

  const rating = review.rating;
  if (typeof rating !== "number" || !Number.isInteger(rating) || rating < 1 || rating > 5) {
    throw new InvalidRequest("review.rating must be 1 to 5");
  }

  return {
    requestId: requestId.toLowerCase(),
    installId: installId.toLowerCase(),
    appName: text(body.appName, "appName", 80) ?? "",
    tone,
    signature: text(body.signature, "signature", 80) ?? "",
    entitlement: text(body.entitlement, "entitlement", 12_000),
    review: {
      platform,
      rating,
      title: text(review.title, "review.title", 300),
      body: text(review.body, "review.body", 6_000, true)!,
      author: text(review.author, "review.author", 100),
      territory: text(review.territory, "review.territory", 8),
      language: text(review.language, "review.language", 16),
    },
  };
}
