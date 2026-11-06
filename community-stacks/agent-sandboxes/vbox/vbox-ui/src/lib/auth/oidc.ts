// The OpenID Connect authorization code flow with PKCE, state and nonce, on
// openid-client. vBox is the relying party; the provider is whatever the Settings
// page names.
import * as client from "openid-client";
import { providerKey, type OidcSettings } from "./settings";
import { getAuthStore, type SessionUser } from "./store";

export class LoginError extends Error {}

const DISCOVERY_TTL_MS = 10 * 60 * 1000;

const globalForOidc = globalThis as unknown as {
  __vboxOidc?: Map<string, { config: client.Configuration; at: number }>;
};
const cache = (globalForOidc.__vboxOidc ??= new Map());

type ProviderFields = Pick<OidcSettings, "issuerUrl" | "clientId" | "clientSecret">;

// Fetches the provider's discovery document (cached for a few minutes). Plain
// http issuers are allowed for local providers such as Dex in a kind cluster.
export async function providerConfig(s: ProviderFields): Promise<client.Configuration> {
  const key = JSON.stringify([s.issuerUrl, s.clientId, s.clientSecret]);
  const hit = cache.get(key);
  if (hit && Date.now() - hit.at < DISCOVERY_TTL_MS) return hit.config;

  let issuer: URL;
  try {
    issuer = new URL(s.issuerUrl);
  } catch {
    throw new LoginError(`The issuer URL "${s.issuerUrl}" is not a valid URL.`);
  }
  const config = await client.discovery(
    issuer,
    s.clientId,
    s.clientSecret || undefined,
    s.clientSecret ? undefined : client.None(),
    issuer.protocol === "http:" ? { execute: [client.allowInsecureRequests] } : undefined,
  );
  cache.set(key, { config, at: Date.now() });
  return config;
}

// Builds the provider's authorization URL and records the login, so the callback
// can verify it. Returns the URL and the state, which the caller also binds to
// the browser in a cookie.
export async function startLogin(s: OidcSettings, redirectUri: string, returnTo: string) {
  const config = await providerConfig(s);
  const codeVerifier = client.randomPKCECodeVerifier();
  const state = client.randomState();
  const nonce = client.randomNonce();
  getAuthStore().saveLoginRequest({ state, codeVerifier, nonce, returnTo });
  const url = client.buildAuthorizationUrl(config, {
    redirect_uri: redirectUri,
    scope: s.scopes,
    code_challenge: await client.calculatePKCECodeChallenge(codeVerifier),
    code_challenge_method: "S256",
    state,
    nonce,
  });
  return { url, state };
}

const claimString = (v: unknown) => (typeof v === "string" && v ? v : undefined);
const claimList = (v: unknown): string[] =>
  Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : typeof v === "string" ? [v] : [];

// Handles the provider's redirect back: checks state against the browser's
// cookie, redeems the code, validates the ID token, and applies the group
// restriction. Returns who signed in and where they were going.
export async function completeLogin(
  s: OidcSettings,
  redirectUri: string,
  search: string,
  browserState: string | undefined,
): Promise<{ user: Omit<SessionUser, "expiresAt">; returnTo: string }> {
  const params = new URLSearchParams(search);
  const error = params.get("error");
  if (error) throw new LoginError(params.get("error_description") ?? `The provider returned "${error}".`);

  const state = params.get("state");
  if (!state || !browserState || state !== browserState) {
    throw new LoginError("This sign-in was not started from this browser, or it took too long. Please try again.");
  }
  const request = getAuthStore().takeLoginRequest(state);
  if (!request) throw new LoginError("This sign-in has expired or was already used. Please try again.");

  const config = await providerConfig(s);
  // The token request's redirect_uri is derived from this URL, so it is rebuilt
  // from the public redirect URI rather than taken from the incoming request,
  // whose host may be the pod's own behind a load balancer.
  const currentUrl = new URL(redirectUri);
  currentUrl.search = search;
  const tokens = await client.authorizationCodeGrant(config, currentUrl, {
    pkceCodeVerifier: request.codeVerifier,
    expectedState: state,
    expectedNonce: request.nonce,
    idTokenExpected: true,
  });
  const idClaims = tokens.claims();
  if (!idClaims) throw new LoginError("The provider returned no ID token.");

  // Userinfo fills in what the ID token leaves out (some providers put only sub in
  // it). The ID token's own claims win, since they are signed.
  let claims: Record<string, unknown> = { ...idClaims };
  if (config.serverMetadata().userinfo_endpoint && tokens.access_token) {
    try {
      const info = await client.fetchUserInfo(config, tokens.access_token, idClaims.sub);
      claims = { ...info, ...idClaims };
    } catch {
      // Best effort: the ID token alone is enough to sign in.
    }
  }

  const username =
    claimString(claims[s.usernameClaim]) ??
    claimString(claims.preferred_username) ??
    claimString(claims.email) ??
    idClaims.sub;
  const groups = claimList(claims[s.groupsClaim]);
  if (s.allowedGroups.length > 0 && !groups.some((g) => s.allowedGroups.includes(g))) {
    throw new LoginError(
      `${username} is not a member of a group allowed to sign in to vBox` +
        (groups.length === 0 ? ` (the "${s.groupsClaim}" claim was empty or missing).` : "."),
    );
  }

  return {
    user: {
      provider: providerKey(s),
      subject: idClaims.sub,
      username,
      name: claimString(claims.name),
      email: claimString(claims.email),
      groups,
      idToken: tokens.id_token,
    },
    returnTo: request.returnTo,
  };
}

// The provider's end-session URL, or undefined when it has none.
export async function endSessionUrl(s: OidcSettings, postLogoutRedirectUri: string, idToken?: string) {
  const config = await providerConfig(s);
  if (!config.serverMetadata().end_session_endpoint) return undefined;
  return client.buildEndSessionUrl(config, {
    post_logout_redirect_uri: postLogoutRedirectUri,
    ...(idToken ? { id_token_hint: idToken } : { client_id: s.clientId }),
  });
}

// Messages from openid-client and fetch are technical but useful to whoever
// configured the provider; keep them, bounded.
export function errorText(err: unknown): string {
  const e = err as Error & { cause?: unknown; error_description?: string };
  // fetch reports "fetch failed" and puts the reason (ECONNREFUSED, a TLS error)
  // in cause, sometimes only as a code.
  const c = e.cause as (Error & { code?: string }) | undefined;
  const reason = c instanceof Error ? c.message || c.code || c.name : "";
  const cause = reason ? `: ${reason}` : "";
  const text = e.error_description ?? `${e.message ?? String(err)}${cause}`;
  return text.length > 300 ? `${text.slice(0, 300)}…` : text;
}
