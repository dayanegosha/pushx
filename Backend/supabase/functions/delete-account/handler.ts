export interface AppleClaims {
  sub: string;
  iat: number;
}
export interface AuthUser {
  id: string;
  identities?: Array<{
    provider: string;
    id?: string;
    provider_id?: string;
    identity_data?: { sub?: string };
  }>;
}
export interface Dependencies {
  allowedOrigins: ReadonlySet<string>;
  getUser: (sessionJWT: string) => Promise<AuthUser | null>;
  verifyAppleToken: (token: string) => Promise<AppleClaims>;
  exchangeCode: (code: string) => Promise<{ idToken: string; revokeToken: string; tokenHint: string }>;
  revokeToken: (token: string, hint: string) => Promise<void>;
  deleteUser: (id: string) => Promise<void>;
  now: () => number;
}
export class OperationError extends Error {
  readonly code: string;
  readonly status: number;
  constructor(code: string, status: number) {
    super(code);
    this.code = code;
    this.status = status;
  }
}

function appleSubjects(user: AuthUser): Set<string> {
  const values = new Set<string>();
  for (const identity of user.identities ?? []) {
    if (identity.provider !== "apple") continue;
    const subject = identity.identity_data?.sub ?? identity.provider_id ?? identity.id;
    if (typeof subject === "string" && subject.length) values.add(subject);
  }
  return values;
}

export function createHandler(deps: Dependencies): (request: Request) => Promise<Response> {
  return async (request) => {
    const origin = request.headers.get("origin");
    const headers = new Headers({
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      "Vary": "Origin",
      "X-Content-Type-Options": "nosniff",
    });
    const respond = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers });
    if (origin && !deps.allowedOrigins.has(origin)) return respond({ error: "origin_not_allowed" }, 403);
    if (origin) {
      headers.set("Access-Control-Allow-Origin", origin);
      headers.set("Access-Control-Allow-Headers", "authorization, apikey, content-type, x-client-info");
      headers.set("Access-Control-Allow-Methods", "POST, OPTIONS");
    }
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers });
    if (request.method !== "POST") {
      headers.set("Allow", "POST, OPTIONS");
      return respond({ error: "method_not_allowed" }, 405);
    }
    try {
      const bearer = request.headers.get("authorization")?.match(/^Bearer (\S+)$/i)?.[1];
      if (!bearer || bearer.length > 16384) return respond({ error: "authentication_required" }, 401);
      const user = await deps.getUser(bearer);
      if (!user) return respond({ error: "authentication_required" }, 401);
      if (!request.headers.get("content-type")?.toLowerCase().startsWith("application/json")) {
        return respond({ error: "invalid_request" }, 400);
      }
      const reader = request.body?.getReader();
      if (!reader) return respond({ error: "invalid_request" }, 400);
      let length = 0;
      const chunks: Uint8Array[] = [];
      while (true) {
        const chunk = await reader.read();
        if (chunk.done) break;
        length += chunk.value.byteLength;
        if (length > 16384) {
          await reader.cancel();
          return respond({ error: "invalid_request" }, 400);
        }
        chunks.push(chunk.value);
      }
      const bytes = new Uint8Array(length);
      let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
      let input: unknown;
      try { input = JSON.parse(new TextDecoder().decode(bytes)); }
      catch { return respond({ error: "invalid_request" }, 400); }
      if (!input || typeof input !== "object" || Array.isArray(input)) return respond({ error: "invalid_request" }, 400);
      const { authorizationCode, idToken } = input as Record<string, unknown>;
      if (typeof authorizationCode !== "string" || authorizationCode.length < 8 || authorizationCode.length > 4096
        || typeof idToken !== "string" || idToken.length < 20 || idToken.length > 12000) {
        return respond({ error: "invalid_request" }, 400);
      }
      const subjects = appleSubjects(user);
      if (!subjects.size) return respond({ error: "apple_identity_mismatch" }, 403);
      let apple: AppleClaims;
      try { apple = await deps.verifyAppleToken(idToken); }
      catch { return respond({ error: "apple_reauthentication_required" }, 401); }
      const age = deps.now() - apple.iat;
      if (!Number.isFinite(age) || age < -30 || age > 300) {
        return respond({ error: "apple_reauthentication_required" }, 401);
      }
      if (!subjects.has(apple.sub)) return respond({ error: "apple_identity_mismatch" }, 403);
      const exchanged = await deps.exchangeCode(authorizationCode);
      let exchangedClaims: AppleClaims;
      try { exchangedClaims = await deps.verifyAppleToken(exchanged.idToken); }
      catch { return respond({ error: "apple_authorization_failed" }, 400); }
      if (exchangedClaims.sub !== apple.sub) return respond({ error: "apple_identity_mismatch" }, 403);
      await deps.revokeToken(exchanged.revokeToken, exchanged.tokenHint);
      await deps.deleteUser(user.id);
      return respond({ deleted: true });
    } catch (error) {
      if (error instanceof OperationError) return respond({ error: error.code }, error.status);
      return respond({ error: "service_unavailable" }, 503);
    }
  };
}
