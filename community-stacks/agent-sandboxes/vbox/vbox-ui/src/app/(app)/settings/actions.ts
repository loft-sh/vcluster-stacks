"use server";

import { revalidatePath } from "next/cache";
import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { errorText, providerConfig } from "@/lib/auth/oidc";
import { SESSION_COOKIE, sessionFor } from "@/lib/auth/request";
import { currentUser, requireUser } from "@/lib/auth/session";
import {
  authModeOf,
  getOidcSettings,
  getOidcState,
  saveOidcSettings,
  SettingsConflictError,
  type OidcSettings,
} from "@/lib/auth/settings";

export interface SettingsState {
  ok?: boolean;
  message?: string;
  // What discovery found, after a test or a save.
  provider?: { issuer: string; authorization: string; token: string; endSession?: string; pkce: boolean };
}

const text = (form: FormData, key: string) => String(form.get(key) ?? "").trim();

async function parse(form: FormData): Promise<OidcSettings> {
  const current = await getOidcSettings();
  const secret = text(form, "clientSecret");
  const scopes = text(form, "scopes").split(/\s+/).filter(Boolean);
  return {
    enabled: form.get("enabled") === "on",
    displayName: text(form, "displayName") || "OpenID Connect",
    issuerUrl: text(form, "issuerUrl").replace(/\/+$/, ""),
    clientId: text(form, "clientId"),
    // Blank keeps the stored secret; the page never sends it back to the browser.
    clientSecret: form.get("clearSecret") === "on" ? "" : secret || current.clientSecret,
    scopes: (scopes.includes("openid") ? scopes : ["openid", ...scopes]).join(" "),
    usernameClaim: text(form, "usernameClaim") || "email",
    groupsClaim: text(form, "groupsClaim") || "groups",
    allowedGroups: text(form, "allowedGroups")
      .split(/[\s,]+/)
      .filter(Boolean),
    providerLogout: form.get("providerLogout") === "on",
  };
}

function validate(s: OidcSettings): string | undefined {
  if (!s.enabled && !s.issuerUrl) return undefined;
  if (!s.issuerUrl) return "Enter the issuer URL.";
  let url: URL;
  try {
    url = new URL(s.issuerUrl);
  } catch {
    return "The issuer URL is not a valid URL.";
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") return "The issuer URL must start with https://.";
  if (!s.clientId) return "Enter the client ID.";
  return undefined;
}

async function discover(s: OidcSettings): Promise<SettingsState["provider"]> {
  const m = (await providerConfig(s)).serverMetadata();
  return {
    issuer: m.issuer,
    authorization: m.authorization_endpoint ?? "-",
    token: m.token_endpoint ?? "-",
    endSession: m.end_session_endpoint,
    pkce: m.code_challenge_methods_supported?.includes("S256") ?? false,
  };
}

export async function submitSettings(_prev: SettingsState, form: FormData): Promise<SettingsState> {
  // Open while sign-in is not enforced, so the first provider can be set up.
  await requireUser("/settings");
  const s = await parse(form);
  const invalid = validate(s);
  if (invalid) return { ok: false, message: invalid };

  let provider: SettingsState["provider"];
  if (s.issuerUrl) {
    try {
      provider = await discover(s);
    } catch (err) {
      return { ok: false, message: `Discovery failed for ${s.issuerUrl}: ${errorText(err)}` };
    }
  }

  if (form.get("intent") === "test") {
    return { ok: true, message: "The provider's discovery document was found.", provider };
  }

  const user = await currentUser();
  try {
    await saveOidcSettings(s, text(form, "version") || undefined, user?.username);
  } catch (err) {
    if (err instanceof SettingsConflictError) {
      return {
        ok: false,
        message:
          "The settings were changed elsewhere (for example with kubectl) after this page was loaded. Reload the page to see them, then save again.",
      };
    }
    const status = (err as { code?: number }).code;
    return {
      ok: false,
      message:
        status === 403
          ? "The vbox service account may not update this Secret. The chart grants update only on the Secret named by oidc.secretName; it must be the annotated one."
          : `The settings could not be saved: ${errorText(err)}`,
    };
  }
  revalidatePath("/", "layout");

  // Sign-in has just been switched on (or the provider changed, which ends every
  // session): sign in now rather than at the next click.
  // Checked afresh: currentUser() is memoized from before the save.
  const token = (await cookies()).get(SESSION_COOKIE)?.value;
  const saved = await getOidcState();
  if (authModeOf(saved) === "enforced" && !(await sessionFor(token))) redirect("/login?next=/settings");
  return {
    ok: true,
    message: s.enabled ? "Saved. Sign-in is required." : "Saved. Sign-in is off.",
    provider,
  };
}
