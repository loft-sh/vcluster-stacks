// Starts a sign-in: sends the browser to the provider's authorization endpoint.
import { NextResponse, type NextRequest } from "next/server";
import { errorText, startLogin } from "@/lib/auth/oidc";
import { cookieOptions, LOGIN_COOKIE, publicOrigin, redirectUriFor, safeReturnTo } from "@/lib/auth/request";
import { authModeOf, getOidcState } from "@/lib/auth/settings";
import { LOGIN_REQUEST_TTL_MS } from "@/lib/auth/store";

export const dynamic = "force-dynamic";

export async function GET(request: NextRequest) {
  const origin = publicOrigin(request.headers);
  const state = await getOidcState();
  const settings = state.settings;
  if (authModeOf(state) !== "enforced") return NextResponse.redirect(new URL("/login", origin));

  const returnTo = safeReturnTo(request.nextUrl.searchParams.get("next"));
  try {
    const { url, state } = await startLogin(settings, redirectUriFor(origin), returnTo);
    const res = NextResponse.redirect(url);
    res.cookies.set(LOGIN_COOKIE, state, { ...cookieOptions(origin), maxAge: LOGIN_REQUEST_TTL_MS / 1000 });
    return res;
  } catch (err) {
    const back = new URL("/login", origin);
    back.searchParams.set("error", `Could not reach the identity provider: ${errorText(err)}`);
    return NextResponse.redirect(back);
  }
}
