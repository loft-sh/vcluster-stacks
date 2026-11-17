// Signs out: deletes the session, and with providerLogout on, also sends the
// browser to the provider's end-session endpoint. POST only, and the session
// cookie is SameSite=Lax, so another site cannot sign a user out.
import { NextResponse, type NextRequest } from "next/server";
import { endSessionUrl } from "@/lib/auth/oidc";
import { postLogoutUriFor, publicOrigin, SESSION_COOKIE } from "@/lib/auth/request";
import { getOidcSettings } from "@/lib/auth/settings";
import { getAuthStore } from "@/lib/auth/store";

export const dynamic = "force-dynamic";

export async function POST(request: NextRequest) {
  const origin = publicOrigin(request.headers);
  const store = getAuthStore();
  const token = request.cookies.get(SESSION_COOKIE)?.value;
  const session = token ? store.getSession(token) : undefined;
  if (token) store.deleteSession(token);

  let target: URL = new URL(postLogoutUriFor(origin));
  const settings = await getOidcSettings();
  if (settings.providerLogout && settings.issuerUrl) {
    try {
      target = (await endSessionUrl(settings, postLogoutUriFor(origin), session?.idToken)) ?? target;
    } catch {
      // Provider unreachable: the vBox session is gone either way.
    }
  }
  // 303 so the browser follows with a GET.
  const res = NextResponse.redirect(target, 303);
  res.cookies.delete(SESSION_COOKIE);
  return res;
}
