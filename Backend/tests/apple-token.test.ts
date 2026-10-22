import assert from "node:assert/strict";
import { createLocalJWKSet, exportJWK, generateKeyPair, SignJWT, type JWTPayload } from "jose";
import { createAppleTokenVerifier } from "../supabase/functions/delete-account/apple.ts";

const pair = await generateKeyPair("RS256");
const jwk = { ...await exportJWK(pair.publicKey), kid: "apple-test", alg: "RS256", use: "sig" };
const verify = createAppleTokenVerifier("app.pushx", createLocalJWKSet({ keys: [jwk] }));
const now = Math.floor(Date.now() / 1000);
const valid: JWTPayload = {
  sub: "apple-subject", iat: now, exp: now + 300, aud: "app.pushx", iss: "https://appleid.apple.com",
};
const sign = (payload: JWTPayload) => new SignJWT(payload)
  .setProtectedHeader({ alg: "RS256", kid: "apple-test" }).sign(pair.privateKey);

Deno.test("accepts a signed Apple-shaped token using the trusted RSA key", async () => {
  assert.deepEqual(await verify(await sign(valid)), { sub: "apple-subject", iat: now });
});
Deno.test("rejects tokens signed by a different RSA key", async () => {
  const attacker = await generateKeyPair("RS256");
  const token = await new SignJWT(valid).setProtectedHeader({ alg: "RS256", kid: "apple-test" }).sign(attacker.privateKey);
  await assert.rejects(verify(token));
});
Deno.test("rejects altered JWT payloads", async () => {
  const parts = (await sign(valid)).split(".");
  parts[1] = btoa(JSON.stringify({ ...valid, sub: "victim" })).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
  await assert.rejects(verify(parts.join(".")));
});
Deno.test("rejects another app audience or issuer", async () => {
  for (const payload of [{ ...valid, aud: "attacker.app" }, { ...valid, iss: "https://attacker.example" }]) {
    await assert.rejects(verify(await sign(payload)));
  }
});
Deno.test("rejects expired and not-yet-valid signed tokens", async () => {
  for (const payload of [{ ...valid, exp: now - 31 }, { ...valid, nbf: now + 60 }]) {
    await assert.rejects(verify(await sign(payload)));
  }
});
Deno.test("requires subject, issue date, and expiry claims", async () => {
  for (const field of ["sub", "iat", "exp"]) {
    const payload = { ...valid };
    delete payload[field];
    await assert.rejects(verify(await sign(payload)));
  }
});
Deno.test("rejects an empty signed subject", async () => {
  await assert.rejects(verify(await sign({ ...valid, sub: "" })));
});
Deno.test("does not accept HMAC as a substitute for RSA", async () => {
  const token = await new SignJWT(valid).setProtectedHeader({ alg: "HS256", kid: "apple-test" })
    .sign(crypto.getRandomValues(new Uint8Array(32)));
  await assert.rejects(verify(token));
});
