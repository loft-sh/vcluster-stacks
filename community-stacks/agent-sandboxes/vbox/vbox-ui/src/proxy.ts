// Turns away requests without a valid session while sign-in is enforced: pages
// redirect to /login, API calls get a 401. Runs on the Node.js runtime, so it
// reads the session straight from auth.db, and the settings through the same
// cached reader as everything else.
//
// Not the only check: pages, Server Functions and Route Handlers verify the
// session again through src/lib/auth/session.ts.
import { NextResponse, type NextRequest } from "next/server";
import { publicOrigin, SESSION_COOKIE, sessionFor } from "@/lib/auth/request";
import { authMode } from "@/lib/auth/settings";

export async function proxy(request: NextRequest) {
  const mode = await authMode();
  if (mode === "not-configured" || mode === "disabled-by-env") return NextResponse.next();
  if (mode === "enforced" && (await sessionFor(request.cookies.get(SESSION_COOKIE)?.value))) return NextResponse.next();

  // Signed out, or the settings could not be read (fail closed: the sign-in page
  // says why).
  const { pathname, search } = request.nextUrl;
  if (pathname.startsWith("/api/")) {
    return mode === "unavailable"
      ? Response.json({ error: "Sign-in settings unavailable" }, { status: 503 })
      : Response.json({ error: "Sign in required" }, { status: 401 });
  }
  const login = new URL("/login", publicOrigin(request.headers));
  if (pathname !== "/") login.searchParams.set("next", pathname + search);
  return NextResponse.redirect(login);
}

export const config = {
  // Everything except static assets, the tab icon, the sign-in page and its
  // routes, and the health check that probes call without a session.
  matcher: ["/((?!_next/static|_next/image|favicon.ico|icon.svg|login|api/auth/|api/healthz).*)"],
};
