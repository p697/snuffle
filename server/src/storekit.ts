// Verifies a StoreKit 2 signed transaction (JWS) the app sends as proof of Pro.
// The certificate chain in the header must end in Apple Root CA - G3, each link must be signed by the next,
// carry Apple's marker extensions and be valid now; then the JWS signature is checked with the leaf key.
import { X509Certificate } from "@peculiar/x509";
import { APPLE_ROOT_CA_G3 } from "./apple-root.ts";

const INTERMEDIATE_MARKER = "1.2.840.113635.100.6.2.1";
const LEAF_MARKER = "1.2.840.113635.100.6.11.1";

export interface SignedTransaction {
  originalTransactionId: string;
  transactionId: string;
  productId: string;
  bundleId: string;
  environment: string;
  purchaseDate: Date;
  expiresDate: Date | null;
  revocationDate: Date | null;
}

export class InvalidTransaction extends Error {}

export interface VerifyOptions {
  bundleId: string;
  now: Date;
  /** Local StoreKit testing in Xcode signs with a certificate that does not chain to Apple. Never on in production. */
  allowXcode: boolean;
  /** Test hook: a different trusted root. */
  root?: X509Certificate;
}

function base64UrlDecode(part: string): Uint8Array<ArrayBuffer> {
  const binary = atob(part.replaceAll("-", "+").replaceAll("_", "/") + "===".slice((part.length + 3) % 4));
  const bytes = new Uint8Array(new ArrayBuffer(binary.length));
  for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

function sameBytes(a: ArrayBuffer, b: ArrayBuffer): boolean {
  if (a.byteLength !== b.byteLength) return false;
  const x = new Uint8Array(a), y = new Uint8Array(b);
  return x.every((value, index) => value === y[index]);
}

function validAt(cert: X509Certificate, now: Date): boolean {
  return cert.notBefore.getTime() <= now.getTime() && now.getTime() <= cert.notAfter.getTime();
}

export async function verifySignedTransaction(jws: string, options: VerifyOptions): Promise<SignedTransaction> {
  const parts = jws.split(".");
  if (parts.length !== 3) throw new InvalidTransaction("not a JWS");
  let header: { alg?: string; x5c?: string[] };
  let payload: any;
  try {
    header = JSON.parse(new TextDecoder().decode(base64UrlDecode(parts[0])));
    payload = JSON.parse(new TextDecoder().decode(base64UrlDecode(parts[1])));
  } catch {
    throw new InvalidTransaction("unreadable JWS");
  }
  if (header.alg !== "ES256" || !Array.isArray(header.x5c) || header.x5c.length < 1) {
    throw new InvalidTransaction("unexpected JWS header");
  }

  const chain = header.x5c.map((der) => new X509Certificate(der));
  const leaf = chain[0];
  const xcode = payload.environment === "Xcode";
  if (xcode && !options.allowXcode) throw new InvalidTransaction("Xcode transactions are not accepted here");
  if (!xcode) {
    if (chain.length !== 3) throw new InvalidTransaction("expected a three-certificate chain");
    const [, intermediate, presentedRoot] = chain;
    const root = options.root ?? new X509Certificate(APPLE_ROOT_CA_G3);
    if (!sameBytes(presentedRoot.rawData, root.rawData)) {
      throw new InvalidTransaction("chain does not end in Apple's root");
    }
    if (!(await intermediate.verify({ publicKey: root.publicKey, signatureOnly: true }))) {
      throw new InvalidTransaction("intermediate not signed by the root");
    }
    if (!(await leaf.verify({ publicKey: intermediate.publicKey, signatureOnly: true }))) {
      throw new InvalidTransaction("leaf not signed by the intermediate");
    }
    if (!intermediate.getExtension(INTERMEDIATE_MARKER) || !leaf.getExtension(LEAF_MARKER)) {
      throw new InvalidTransaction("certificates are not App Store certificates");
    }
    if (![leaf, intermediate, root].every((cert) => validAt(cert, options.now))) {
      throw new InvalidTransaction("certificate outside its validity period");
    }
  }

  const key = await leaf.publicKey.export({ name: "ECDSA", namedCurve: "P-256" }, ["verify"]);
  const signed = new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
  const valid = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, base64UrlDecode(parts[2]), signed);
  if (!valid) throw new InvalidTransaction("bad signature");

  if (payload.bundleId !== options.bundleId) throw new InvalidTransaction("transaction is for another app");
  if (typeof payload.originalTransactionId !== "string" || typeof payload.productId !== "string") {
    throw new InvalidTransaction("transaction is missing fields");
  }
  return {
    originalTransactionId: payload.originalTransactionId,
    transactionId: String(payload.transactionId ?? ""),
    productId: payload.productId,
    bundleId: payload.bundleId,
    environment: String(payload.environment ?? ""),
    purchaseDate: new Date(Number(payload.purchaseDate ?? 0)),
    expiresDate: payload.expiresDate ? new Date(Number(payload.expiresDate)) : null,
    revocationDate: payload.revocationDate ? new Date(Number(payload.revocationDate)) : null,
  };
}

export const PRO_PRODUCTS = new Set(["ai.snuffle.pro.monthly", "ai.snuffle.pro.yearly", "ai.snuffle.pro.lifetime"]);

/** Pro is active for an unrevoked lifetime purchase or an unrevoked subscription that has not expired. */
export function grantsPro(transaction: SignedTransaction, now: Date): boolean {
  if (!PRO_PRODUCTS.has(transaction.productId) || transaction.revocationDate) return false;
  if (transaction.productId === "ai.snuffle.pro.lifetime") return true;
  return transaction.expiresDate !== null && transaction.expiresDate.getTime() > now.getTime();
}
