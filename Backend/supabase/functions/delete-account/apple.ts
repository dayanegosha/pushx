import { jwtVerify, type JWTVerifyGetKey } from "jose";
import type { AppleClaims } from "./handler.ts";

export function createAppleTokenVerifier(clientID: string, keys: JWTVerifyGetKey) {
  return async (token: string): Promise<AppleClaims> => {
    const { payload } = await jwtVerify(token, keys, {
      issuer: "https://appleid.apple.com", audience: clientID, algorithms: ["RS256"],
      requiredClaims: ["sub", "iat", "exp"], clockTolerance: 30,
    });
    if (typeof payload.sub !== "string" || !payload.sub || typeof payload.iat !== "number"
      || !Number.isFinite(payload.iat)) throw new Error("invalid_claims");
    return { sub: payload.sub, iat: payload.iat };
  };
}
