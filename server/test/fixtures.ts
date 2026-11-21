// Certificate chains shaped like Apple's, and transactions signed with them.
import * as x509 from "@peculiar/x509";
import type { ModelConfig } from "../src/models.ts";

x509.cryptoProvider.set(crypto);
export const alg = { name: "ECDSA", namedCurve: "P-256", hash: "SHA-256" } as const;
export const now = new Date("2026-11-20T12:00:00Z");
const notBefore = new Date("2026-01-01T00:00:00Z");
const notAfter = new Date("2030-01-01T00:00:00Z");

export function b64url(bytes: Uint8Array | ArrayBuffer): string {
  const array = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  return btoa(String.fromCharCode(...array)).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

/** A chain shaped like Apple's: root → intermediate (WWDR marker) → leaf (App Store marker). */
export async function makeChain(markers = true) {
  const rootKeys = (await crypto.subtle.generateKey(alg, true, ["sign", "verify"])) as CryptoKeyPair;
  const root = await x509.X509CertificateGenerator.createSelfSigned({
    serialNumber: "01",
    name: "CN=Test Root",
    notBefore,
    notAfter,
    keys: rootKeys,
    signingAlgorithm: alg,
    extensions: [new x509.BasicConstraintsExtension(true, 2, true)],
  });
  const interKeys = (await crypto.subtle.generateKey(alg, true, ["sign", "verify"])) as CryptoKeyPair;
  const intermediate = await x509.X509CertificateGenerator.create({
    serialNumber: "02",
    subject: "CN=Test WWDR",
    issuer: root.subject,
    notBefore,
    notAfter,
    signingKey: rootKeys.privateKey,
    publicKey: interKeys.publicKey,
    signingAlgorithm: alg,
    extensions: [
      new x509.BasicConstraintsExtension(true, 0, true),
      ...(markers ? [new x509.Extension("1.2.840.113635.100.6.2.1", false, new Uint8Array([5, 0]))] : []),
    ],
  });
  const leafKeys = (await crypto.subtle.generateKey(alg, true, ["sign", "verify"])) as CryptoKeyPair;
  const leaf = await x509.X509CertificateGenerator.create({
    serialNumber: "03",
    subject: "CN=Test App Store",
    issuer: intermediate.subject,
    notBefore,
    notAfter,
    signingKey: interKeys.privateKey,
    publicKey: leafKeys.publicKey,
    signingAlgorithm: alg,
    extensions: markers ? [new x509.Extension("1.2.840.113635.100.6.11.1", false, new Uint8Array([5, 0]))] : [],
  });
  return { root, intermediate, leaf, leafKeys };
}

export async function sign(payload: Record<string, unknown>, chain: Awaited<ReturnType<typeof makeChain>>): Promise<string> {
  const header = {
    alg: "ES256",
    x5c: [chain.leaf, chain.intermediate, chain.root].map((cert) => cert.toString("base64")),
  };
  const signingInput = `${b64url(new TextEncoder().encode(JSON.stringify(header)))}.${
    b64url(new TextEncoder().encode(JSON.stringify(payload)))
  }`;
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    chain.leafKeys.privateKey,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${b64url(signature)}`;
}

export const yearly = {
  bundleId: "ai.snuffle.app",
  productId: "ai.snuffle.pro.yearly",
  originalTransactionId: "2000000123",
  transactionId: "2000000456",
  environment: "Production",
  purchaseDate: Date.parse("2026-11-01T00:00:00Z"),
  expiresDate: Date.parse("2027-11-01T00:00:00Z"),
};

export const model: ModelConfig = {
  revision: 3,
  provider: "deepseek",
  model: "deepseek-chat",
  max_output_tokens: 700,
  temperature: 0.6,
  input_usd_per_mtok: 0.27,
  output_usd_per_mtok: 1.1,
  extra: {},
};

export const validBody = {
  requestId: "6b2b6e8a-0b4e-4f7a-9c1d-5e0b6b5d1a01",
  installId: "0f1e2d3c-4b5a-4968-8776-655443322110",
  appName: "Lumen Notes",
  tone: "warm",
  signature: "Mia",
  entitlement: "jws",
  review: { platform: "googlePlay", rating: 2, body: "Crashes when I attach a PDF", language: "en_US" },
};
