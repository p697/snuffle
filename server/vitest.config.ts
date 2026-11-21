import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig(async () => {
  const migrations = await readD1Migrations("./migrations");
  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          // Tests sign their own transactions; the local StoreKit (Xcode) ones are allowed here only.
          bindings: { TEST_MIGRATIONS: migrations, SNUFFLE_ALLOW_XCODE_TRANSACTIONS: "true" },
        },
      }),
    ],
    test: { setupFiles: ["./test/apply-migrations.ts"] },
  };
});
