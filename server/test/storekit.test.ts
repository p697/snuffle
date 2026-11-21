import * as x509 from "@peculiar/x509";
import { expect, it } from "vitest";
import { grantsPro, verifySignedTransaction } from "../src/storekit.ts";
import { APPLE_ROOT_CA_G3 } from "../src/apple-root.ts";
import { b64url, makeChain, now, sign, yearly } from "./fixtures.ts";

it("a valid App Store transaction verifies and grants Pro", async () => {
  const chain = await makeChain();
  const transaction = await verifySignedTransaction(await sign(yearly, chain), {
    bundleId: "ai.snuffle.app",
    now,
    allowXcode: false,
    root: chain.root,
  });
  expect(transaction.originalTransactionId).toBe("2000000123");
  expect(grantsPro(transaction, now)).toBe(true);
  expect(grantsPro(transaction, new Date("2028-01-01T00:00:00Z"))).toBe(false);
});

it("tampering, foreign roots, missing markers and other apps are refused", async () => {
  const chain = await makeChain();
  const options = { bundleId: "ai.snuffle.app", now, allowXcode: false, root: chain.root };
  const jws = await sign(yearly, chain);

  const [header, , signature] = jws.split(".");
  const forged = `${header}.${
    b64url(new TextEncoder().encode(JSON.stringify({ ...yearly, productId: "ai.snuffle.pro.lifetime" })))
  }.${signature}`;
  await expect(verifySignedTransaction(forged, options)).rejects.toThrow(/signature/);

  await expect(verifySignedTransaction(jws, { ...options, root: new x509.X509Certificate(APPLE_ROOT_CA_G3) })).rejects.toThrow(/root/);

  const plain = await makeChain(false);
  const unmarked = await sign(yearly, plain);
  await expect(verifySignedTransaction(unmarked, { ...options, root: plain.root })).rejects.toThrow(/App Store certificates/);

  const otherApp = await sign({ ...yearly, bundleId: "com.other" }, chain);
  await expect(verifySignedTransaction(otherApp, options)).rejects.toThrow(/another app/);

  await expect(verifySignedTransaction(jws, { ...options, now: new Date("2031-01-01T00:00:00Z") })).rejects.toThrow(/validity/);
});

it("Xcode test transactions only pass where explicitly allowed", async () => {
  const chain = await makeChain(false);
  const jws = await sign({ ...yearly, environment: "Xcode" }, chain);
  await expect(verifySignedTransaction(jws, { bundleId: "ai.snuffle.app", now, allowXcode: false })).rejects.toThrow(/Xcode/);
  const transaction = await verifySignedTransaction(jws, { bundleId: "ai.snuffle.app", now, allowXcode: true });
  expect(transaction.environment).toBe("Xcode");
});

it("revoked or unknown products never grant Pro", () => {
  const base = {
    originalTransactionId: "1",
    transactionId: "1",
    bundleId: "ai.snuffle.app",
    environment: "Production",
    purchaseDate: now,
    expiresDate: null,
    revocationDate: null,
  };
  expect(grantsPro({ ...base, productId: "ai.snuffle.pro.lifetime" }, now)).toBe(true);
  expect(grantsPro({ ...base, productId: "ai.snuffle.pro.lifetime", revocationDate: now }, now)).toBe(false);
  expect(grantsPro({ ...base, productId: "ai.snuffle.coins" }, now)).toBe(false);
  expect(grantsPro({ ...base, productId: "ai.snuffle.pro.monthly" }, now)).toBe(false);
});
