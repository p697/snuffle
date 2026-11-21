// Checks a signed transaction captured from the app with the server's own verifier.
// Usage: node scripts/verify-jws.ts <file> [--allow-xcode]
import { readFileSync } from "node:fs";
import { grantsPro, verifySignedTransaction } from "../src/storekit.ts";

const [path, flag] = process.argv.slice(2);
const jws = readFileSync(path, "utf8").trim();
const transaction = await verifySignedTransaction(jws, {
  bundleId: "ai.snuffle.app",
  now: new Date(),
  allowXcode: flag === "--allow-xcode",
});
console.log(JSON.stringify({
  productId: transaction.productId,
  environment: transaction.environment,
  expires: transaction.expiresDate?.toISOString() ?? null,
  grantsPro: grantsPro(transaction, new Date()),
}));
