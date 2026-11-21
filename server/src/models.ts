// Model providers. Four speak the OpenAI chat-completions dialect; Anthropic has its own. There is no fallback
// between providers: the active row in `model_config` decides, and switching is an operator action.

export type Provider = "openai" | "anthropic" | "deepseek" | "dashscope" | "openrouter";

export interface ModelConfig {
  revision: number;
  provider: Provider;
  model: string;
  max_output_tokens: number;
  temperature: number | null;
  input_usd_per_mtok: number;
  output_usd_per_mtok: number;
  extra: Record<string, unknown>;
}

export interface Completion {
  text: string;
  inputTokens: number | null;
  outputTokens: number | null;
}

export class ProviderError extends Error {
  constructor(message: string, readonly status?: number) {
    super(message);
  }
}

const OPENAI_COMPATIBLE: Record<Exclude<Provider, "anthropic">, string> = {
  openai: "https://api.openai.com/v1",
  deepseek: "https://api.deepseek.com",
  dashscope: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
  openrouter: "https://openrouter.ai/api/v1",
};

/** Each provider's key is its own Snuffle key, kept in function secrets under this name. */
export function keyName(provider: Provider): string {
  return `SNUFFLE_${provider.toUpperCase()}_API_KEY`;
}

/** Cost in USD from token counts; unknown usage costs the estimate, never zero. */
export function costUsd(config: ModelConfig, input: number | null, output: number | null, estimate: number): number {
  if (input === null || output === null) return estimate;
  return (input * config.input_usd_per_mtok + output * config.output_usd_per_mtok) / 1_000_000;
}

/** Upper bound reserved before the call: a generous input estimate plus the full output allowance. */
export function estimateUsd(config: ModelConfig, promptChars: number): number {
  const inputTokens = Math.ceil(promptChars / 2) + 300;
  return (inputTokens * config.input_usd_per_mtok + config.max_output_tokens * config.output_usd_per_mtok) / 1_000_000;
}

export async function complete(
  config: ModelConfig,
  system: string,
  user: string,
  apiKey: string,
  fetcher: typeof fetch = fetch,
): Promise<Completion> {
  const signal = AbortSignal.timeout(45_000);
  if (config.provider === "anthropic") {
    const response = await fetcher("https://api.anthropic.com/v1/messages", {
      method: "POST",
      signal,
      headers: { "content-type": "application/json", "x-api-key": apiKey, "anthropic-version": "2023-06-01" },
      body: JSON.stringify({
        model: config.model,
        max_tokens: config.max_output_tokens,
        system,
        messages: [{ role: "user", content: user }],
        ...(config.temperature === null ? {} : { temperature: config.temperature }),
        ...config.extra,
      }),
    });
    const json = await readJson(response);
    const text = Array.isArray(json.content)
      ? json.content.filter((part: { type?: string }) => part.type === "text").map((part: { text: string }) =>
        part.text
      )
        .join("")
      : "";
    return { text, inputTokens: json.usage?.input_tokens ?? null, outputTokens: json.usage?.output_tokens ?? null };
  }

  const base = OPENAI_COMPATIBLE[config.provider];
  // OpenAI's newer models take max_completion_tokens; the compatible providers still use max_tokens.
  const limitField = config.provider === "openai" ? "max_completion_tokens" : "max_tokens";
  const response = await fetcher(`${base}/chat/completions`, {
    method: "POST",
    signal,
    headers: { "content-type": "application/json", authorization: `Bearer ${apiKey}` },
    body: JSON.stringify({
      model: config.model,
      messages: [{ role: "system", content: system }, { role: "user", content: user }],
      [limitField]: config.max_output_tokens,
      response_format: { type: "json_object" },
      ...(config.temperature === null ? {} : { temperature: config.temperature }),
      ...config.extra,
    }),
  });
  const json = await readJson(response);
  return {
    text: json.choices?.[0]?.message?.content ?? "",
    inputTokens: json.usage?.prompt_tokens ?? null,
    outputTokens: json.usage?.completion_tokens ?? null,
  };
}

async function readJson(response: Response): Promise<any> {
  const body = await response.text();
  if (!response.ok) {
    throw new ProviderError(`provider returned ${response.status}: ${body.slice(0, 300)}`, response.status);
  }
  try {
    return JSON.parse(body);
  } catch {
    throw new ProviderError("provider returned a non-JSON body");
  }
}
