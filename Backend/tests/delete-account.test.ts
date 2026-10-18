import test from "node:test";
import assert from "node:assert/strict";
import { createHandler, OperationError, type Dependencies } from "../supabase/functions/delete-account/handler.ts";

const now = 1802810000;
function fixture(overrides: Partial<Dependencies> = {}) {
  const calls: string[] = [];
  const deps: Dependencies = {
    allowedOrigins: new Set(["https://forma.example"]),
    now: () => now,
    getUser: async () => ({ id: "user-1", identities: [{ provider: "apple", identity_data: { sub: "apple-1" } }] }),
    verifyAppleToken: async () => ({ sub: "apple-1", iat: now }),
    exchangeCode: async () => { calls.push("exchange"); return { idToken: "exchanged", revokeToken: "refresh", tokenHint: "refresh_token" }; },
    revokeToken: async () => { calls.push("revoke"); },
    deleteUser: async (id) => { calls.push(`delete:${id}`); },
    ...overrides,
  };
  return { handler: createHandler(deps), calls };
}
function request(options: { origin?: string; authorization?: string; method?: string; body?: unknown } = {}) {
  const method = options.method ?? "POST";
  return new Request("https://project.example/functions/v1/delete-account", {
    method,
    headers: {
      "Content-Type": "application/json",
      ...(options.authorization === "" ? {} : { Authorization: options.authorization ?? "Bearer valid-session" }),
      ...(options.origin ? { Origin: options.origin } : {}),
    },
    ...(method === "POST" ? { body: JSON.stringify(options.body ?? { authorizationCode: "fresh-code", idToken: "valid.apple.identity.token" }) } : {}),
  });
}
async function errorCode(response: Response, status: number, code: string) {
  assert.equal(response.status, status);
  assert.deepEqual(await response.json(), { error: code });
}

test("deletes only after Apple verification, exchange, and revocation", async () => {
  const { handler, calls } = fixture();
  const response = await handler(request());
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { deleted: true });
  assert.deepEqual(calls, ["exchange", "revoke", "delete:user-1"]);
  assert.equal(response.headers.get("cache-control"), "no-store");
});
test("rejects absent/invalid sessions", async () => {
  const { handler, calls } = fixture({ getUser: async () => null });
  await errorCode(await handler(request({ authorization: "" })), 401, "authentication_required");
  await errorCode(await handler(request()), 401, "authentication_required");
  assert.deepEqual(calls, []);
});
test("requires fresh Apple identity token", async () => {
  const { handler, calls } = fixture({ verifyAppleToken: async () => ({ sub: "apple-1", iat: now - 301 }) });
  await errorCode(await handler(request()), 401, "apple_reauthentication_required");
  assert.deepEqual(calls, []);
});
test("rejects invalid Apple signature before any write", async () => {
  const { handler, calls } = fixture({ verifyAppleToken: async () => { throw new Error("signature"); } });
  await errorCode(await handler(request()), 401, "apple_reauthentication_required");
  assert.deepEqual(calls, []);
});
test("requires Apple subject to match trusted Auth identity", async () => {
  const { handler, calls } = fixture({ verifyAppleToken: async () => ({ sub: "attacker", iat: now }) });
  await errorCode(await handler(request()), 403, "apple_identity_mismatch");
  assert.deepEqual(calls, []);
});
test("rejects mixed identity token and authorization code", async () => {
  const { handler, calls } = fixture({ verifyAppleToken: async (token) => ({ sub: token === "exchanged" ? "attacker" : "apple-1", iat: now }) });
  await errorCode(await handler(request()), 403, "apple_identity_mismatch");
  assert.deepEqual(calls, ["exchange"]);
});
test("does not delete if Apple revocation fails", async () => {
  const { handler, calls } = fixture({ revokeToken: async () => { throw new OperationError("apple_revocation_failed", 502); } });
  await errorCode(await handler(request()), 502, "apple_revocation_failed");
  assert.deepEqual(calls, ["exchange"]);
});
test("reports delete failure and never pretends success", async () => {
  const { handler, calls } = fixture({ deleteUser: async () => { throw new OperationError("account_deletion_failed", 502); } });
  await errorCode(await handler(request()), 502, "account_deletion_failed");
  assert.deepEqual(calls, ["exchange", "revoke"]);
});
test("CORS allows only exact configured origins", async () => {
  const { handler } = fixture();
  const allowed = await handler(request({ method: "OPTIONS", origin: "https://forma.example" }));
  assert.equal(allowed.status, 204);
  assert.equal(allowed.headers.get("access-control-allow-origin"), "https://forma.example");
  const denied = await handler(request({ origin: "https://attacker.example" }));
  await errorCode(denied, 403, "origin_not_allowed");
  assert.equal(denied.headers.get("access-control-allow-origin"), null);
});
test("rejects malformed/oversized input", async () => {
  const { handler, calls } = fixture();
  await errorCode(await handler(request({ body: { idToken: "small" } })), 400, "invalid_request");
  await errorCode(await handler(request({ body: { ignored: "x".repeat(20000) } })), 400, "invalid_request");
  await errorCode(await handler(request({ method: "GET" })), 405, "method_not_allowed");
  assert.deepEqual(calls, []);
});
