// Who is signed in, for pages, Server Functions and Route Handlers. src/proxy.ts
// turns away unauthenticated requests first; these helpers check again where the
// data is used, so a matcher change cannot silently open a route.
import { cache } from "react";
import { cookies, headers } from "next/headers";
import { redirect } from "next/navigation";
import { publicOrigin, SESSION_COOKIE, sessionFor } from "./request";
import { authMode } from "./settings";
import type { SessionUser } from "./store";

export const currentUser = cache(async (): Promise<SessionUser | undefined> => {
  return await sessionFor((await cookies()).get(SESSION_COOKIE)?.value);
});

export async function currentOrigin(): Promise<string> {
  return publicOrigin(await headers());
}

// For pages and Server Functions: the signed-in user, or a redirect to the
// sign-in page. Undefined when sign-in is not enforced. When the settings cannot
// be read, the sign-in page explains why and nothing else is served.
export async function requireUser(returnTo = "/sandboxes"): Promise<SessionUser | undefined> {
  const mode = await authMode();
  if (mode === "unavailable") redirect("/login");
  if (mode !== "enforced") return undefined;
  const user = await currentUser();
  if (!user) redirect(`/login?next=${encodeURIComponent(returnTo)}`);
  return user;
}

// For Route Handlers: a 401 response when sign-in is enforced and missing, 503
// when the sign-in settings cannot be read.
export async function unauthorized(): Promise<Response | undefined> {
  const mode = await authMode();
  if (mode === "unavailable") return Response.json({ error: "Sign-in settings unavailable" }, { status: 503 });
  if (mode !== "enforced" || (await currentUser())) return undefined;
  return Response.json({ error: "Sign in required" }, { status: 401 });
}
