import { createRemoteJWKSet, importPKCS8, SignJWT } from "jose";
import { createHandler, OperationError, type AuthUser } from "./handler.ts";
import { createAppleTokenVerifier } from "./apple.ts";

const env = (name: string) => Deno.env.get(name)?.trim() ?? "";
const supabaseURL = env("SUPABASE_URL").replace(/\/$/, "");
const publishableKey = env("SUPABASE_ANON_KEY") || env("SUPABASE_PUBLISHABLE_KEY");
const serviceRole = env("SUPABASE_SERVICE_ROLE_KEY") || env("SUPABASE_SECRET_KEY");
const appleClientID = env("APPLE_CLIENT_ID");
const appleTeamID = env("APPLE_TEAM_ID");
const appleKeyID = env("APPLE_KEY_ID");
const applePrivateKey = env("APPLE_PRIVATE_KEY").replace(/\\n/g, "\n");
const allowedOrigins = new Set(env("ALLOWED_ORIGINS").split(",").map((value) => value.trim()).filter(Boolean));
const appleJWKS = createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"), { timeoutDuration: 10000 });
const configured = Boolean(supabaseURL && publishableKey && serviceRole && appleClientID && appleTeamID && appleKeyID && applePrivateKey);

async function network(url: string, init: RequestInit): Promise<Response> {
  try { return await fetch(url, { ...init, signal: AbortSignal.timeout(15000), redirect: "error" }); }
  catch { throw new OperationError("service_unavailable", 503); }
}

async function clientSecret(): Promise<string> {
  const key = await importPKCS8(applePrivateKey, "ES256");
  return new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: appleKeyID })
    .setIssuer(appleTeamID).setSubject(appleClientID)
    .setAudience("https://appleid.apple.com").setIssuedAt().setExpirationTime("5m").sign(key);
}

const verifyAppleToken = createAppleTokenVerifier(appleClientID, appleJWKS);

const handler = createHandler({
  allowedOrigins,
  now: () => Math.floor(Date.now() / 1000),
  verifyAppleToken,
  getUser: async (jwt) => {
    const response = await network(`${supabaseURL}/auth/v1/user`, {
      method: "GET", headers: { apikey: publishableKey, Authorization: `Bearer ${jwt}` },
    });
    if (response.status === 401 || response.status === 403) return null;
    if (!response.ok) throw new OperationError("service_unavailable", 503);
    const user = await response.json() as AuthUser;
    return typeof user.id === "string" && user.id ? user : null;
  },
  exchangeCode: async (code) => {
    const response = await network("https://appleid.apple.com/auth/token", {
      method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ client_id: appleClientID, client_secret: await clientSecret(), code, grant_type: "authorization_code" }),
    });
    if (!response.ok) throw new OperationError("apple_authorization_failed", 400);
    const result = await response.json() as { id_token?: string; refresh_token?: string; access_token?: string };
    const revokeToken = result.refresh_token ?? result.access_token;
    if (!result.id_token || !revokeToken) throw new OperationError("apple_authorization_failed", 400);
    return { idToken: result.id_token, revokeToken, tokenHint: result.refresh_token ? "refresh_token" : "access_token" };
  },
  revokeToken: async (token, hint) => {
    const response = await network("https://appleid.apple.com/auth/revoke", {
      method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ client_id: appleClientID, client_secret: await clientSecret(), token, token_type_hint: hint }),
    });
    if (!response.ok) throw new OperationError("apple_revocation_failed", 502);
  },
  deleteUser: async (id) => {
    const response = await network(`${supabaseURL}/auth/v1/admin/users/${encodeURIComponent(id)}`, {
      method: "DELETE",
      headers: {
        apikey: serviceRole,
        ...(serviceRole.startsWith("sb_secret_") ? {} : { Authorization: `Bearer ${serviceRole}` }),
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ should_soft_delete: false }),
    });
    if (!response.ok) throw new OperationError("account_deletion_failed", 502);
  },
});

Deno.serve((request) => {
  if (!configured) return Response.json({ error: "service_not_configured" }, { status: 503, headers: { "Cache-Control": "no-store" } });
  return handler(request);
});
