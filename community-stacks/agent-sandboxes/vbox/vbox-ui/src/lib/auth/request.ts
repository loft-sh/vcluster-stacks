// Cookie names and request-level helpers shared by src/proxy.ts and the Route
// Handlers. Nothing here reads next/headers, so the proxy can import it.
import { getOidcSettings, providerKey } from "./settings";
import { getAuthStore, type SessionUser } from "./store";

export const SESSION_COOKIE = "vbox_session";
// Binds an in-flight login to the browser that started it.
export const LOGIN_COOKIE = "vbox_login";

// The session behind a cookie value, if it is valid under the current provider.
export async function sessionFor(token: string | undefined): Promise<SessionUser | undefined> {
  if (!token) return undefined;
  const user = getAuthStore().getSession(token);
  return user && user.provider === providerKey(await getOidcSettings()) ? user : undefined;
}

// The origin browsers reach vBox at, for the redirect URI and redirects.
// VBOX_PUBLIC_URL wins; otherwise the forwarded headers set by the ingress or
// load balancer, then Host.
export function publicOrigin(h: Headers): string {
  const configured = process.env.VBOX_PUBLIC_URL;
  if (configured) return new URL(configured).origin;
  const host = h.get("x-forwarded-host")?.split(",")[0].trim() ?? h.get("host") ?? "localhost:3000";
  const proto = h.get("x-forwarded-proto")?.split(",")[0].trim() ?? "http";
  return `${proto}://${host}`;
}

export const redirectUriFor = (origin: string) => `${origin}/api/auth/callback`;
export const postLogoutUriFor = (origin: string) => `${origin}/login?signedOut=1`;

export const cookieOptions = (origin: string) => ({
  httpOnly: true,
  sameSite: "lax" as const,
  secure: origin.startsWith("https:"),
  path: "/",
});

// Only same-site paths, so the post-login redirect cannot be pointed elsewhere.
export function safeReturnTo(next: string | null | undefined): string {
  if (!next || !next.startsWith("/") || next.startsWith("//") || next.startsWith("/\\")) return "/sandboxes";
  if (next.startsWith("/login") || next.startsWith("/api/auth/")) return "/sandboxes";
  return next;
}
