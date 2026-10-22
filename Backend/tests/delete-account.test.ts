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
test("ignores untrusted user IDs and editable user metadata", async () => {
  const { handler, calls } = fixture();
  const response = await handler(request({ body: {
    authorizationCode: "fresh-code", idToken: "valid.apple.identity.token", user_id: "victim",
    user_metadata: { provider: "apple", sub: "victim-apple" },
  } }));
  assert.equal(response.status, 200);
  assert.deepEqual(calls, ["exchange", "revoke", "delete:user-1"]);
});
test("does not treat another identity provider as Apple", async () => {
  const { handler, calls } = fixture({ getUser: async () => ({
    id: "user-1", identities: [{ provider: "email", identity_data: { sub: "apple-1" } }],
  }) });
  await errorCode(await handler(request()), 403, "apple_identity_mismatch");
  assert.deepEqual(calls, []);
});
test("rejects future and non-finite Apple token issue dates", async () => {
  for (const iat of [now + 31, NaN, Infinity, -Infinity]) {
    const { handler, calls } = fixture({ verifyAppleToken: async () => ({ sub: "apple-1", iat }) });
    await errorCode(await handler(request()), 401, "apple_reauthentication_required");
    assert.deepEqual(calls, []);
  }
});
test("does not revoke or delete after an invalid exchanged identity token", async () => {
  const { handler, calls } = fixture({ verifyAppleToken: async (token) => {
    if (token === "exchanged") throw new Error("signature");
    return { sub: "apple-1", iat: now };
  } });
  await errorCode(await handler(request()), 400, "apple_authorization_failed");
  assert.deepEqual(calls, ["exchange"]);
});
test("does not exchange any Apple code when authentication service fails", async () => {
  const { handler, calls } = fixture({ getUser: async () => { throw new Error("unavailable"); } });
  await errorCode(await handler(request()), 503, "service_unavailable");
  assert.deepEqual(calls, []);
});
test("only accepts the exact JSON media type", async () => {
  const { handler, calls } = fixture();
  const input = request();
  input.headers.set("Content-Type", "application/jsonp");
  await errorCode(await handler(input), 400, "invalid_request");
  assert.deepEqual(calls, []);
  const valid = request();
  valid.headers.set("Content-Type", "Application/JSON; charset=utf-8");
  assert.equal((await handler(valid)).status, 200);
});
test("rejects malformed JSON and non-object JSON without any account mutation", async () => {
  for (const body of ["{", "null", "[]", "true", '"apple"']) {
    const { handler, calls } = fixture();
    const input = new Request(request(), { body });
    await errorCode(await handler(input), 400, "invalid_request");
    assert.deepEqual(calls, []);
  }
});
test("limits the total body across chunks and cancels the stream", async () => {
  const { handler, calls } = fixture();
  let cancelled = false;
  const stream = new ReadableStream<Uint8Array>({
    pull(controller) { controller.enqueue(new Uint8Array(9000)); },
    cancel() { cancelled = true; },
  });
  const input = new Request(request(), { body: stream, duplex: "half" } as RequestInit);
  await errorCode(await handler(input), 400, "invalid_request");
  assert.equal(cancelled, true);
  assert.deepEqual(calls, []);
});
test("stalled request bodies expire without consuming an Apple code", async () => {
  const { handler, calls } = fixture({ bodyTimeoutMilliseconds: 10 });
  let cancelled = false;
  const stream = new ReadableStream<Uint8Array>({ cancel() { cancelled = true; } });
  const input = new Request(request(), { body: stream, duplex: "half" } as RequestInit);
  await errorCode(await handler(input), 400, "invalid_request");
  assert.equal(cancelled, true);
  assert.deepEqual(calls, []);
});
test("rejects malformed UTF-8 rather than replacing bytes in credentials", async () => {
  const { handler, calls } = fixture();
  const prefix = new TextEncoder().encode('{"authorizationCode":"fresh-code","idToken":"valid.apple.identity.');
  const suffix = new TextEncoder().encode('token"}');
  const body = new Uint8Array([...prefix, 0xff, ...suffix]);
  await errorCode(await handler(new Request(request(), { body })), 400, "invalid_request");
  assert.deepEqual(calls, []);
});
