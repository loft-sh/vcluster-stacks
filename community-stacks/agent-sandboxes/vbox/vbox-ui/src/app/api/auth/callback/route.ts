// The redirect URI: the provider sends the browser back here with a code, which
// is redeemed for tokens and turned into a vBox session.
import { NextResponse, type NextRequest } from "next/server";
import { completeLogin, errorText } from "@/lib/auth/oidc";
import { cookieOptions, LOGIN_COOKIE, publicOrigin, redirectUriFor, SESSION_COOKIE } from "@/lib/auth/request";
import { authModeOf, getOidcState } from "@/lib/auth/settings";
import { getAuthStore } from "@/lib/auth/store";

export const dynamic = "force-dynamic";

export async function GET(request: NextRequest) {
  const origin = publicOrigin(request.headers);
  const state = await getOidcState();
  const settings = state.settings;
  if (authModeOf(state) !== "enforced") return NextResponse.redirect(new URL("/login", origin));

  try {
    const { user, returnTo } = await completeLogin(
      settings,
      redirectUriFor(origin),
      request.nextUrl.search,
      request.cookies.get(LOGIN_COOKIE)?.value,
    );
    const { token, expiresAt } = getAuthStore().createSession(user);
    const res = NextResponse.redirect(new URL(returnTo, origin));
    res.cookies.set(SESSION_COOKIE, token, { ...cookieOptions(origin), expires: new Date(expiresAt) });
    res.cookies.delete(LOGIN_COOKIE);
    return res;
  } catch (err) {
    const back = new URL("/login", origin);
    back.searchParams.set("error", errorText(err));
    const res = NextResponse.redirect(back);
    res.cookies.delete(LOGIN_COOKIE);
    return res;
  }
}
