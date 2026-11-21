// snuffle.ai: static assets for the site, and the drafting API under /api (the only paths that reach this code).
import { fail, handleDraft } from "./draft-handler.ts";
import { type AppEnv, liveDeps } from "./deps.ts";

export default {
  async fetch(request, env, ctx): Promise<Response> {
    const { pathname } = new URL(request.url);
    if (pathname === "/api/v1/draft-reply") return handleDraft(request, liveDeps(env, ctx));
    if (pathname.startsWith("/api/")) return fail(404, "not_found", "no such endpoint");
    return env.ASSETS.fetch(request);
  },
} satisfies ExportedHandler<AppEnv>;
