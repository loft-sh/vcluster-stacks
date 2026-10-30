import type { Metadata } from "next";
import Link from "next/link";
import { redirect } from "next/navigation";
import { connection } from "next/server";
import { CircleAlert, CircleCheck, LogIn } from "lucide-react";
import { VBoxLogo } from "@/components/vbox-logo";
import { safeReturnTo } from "@/lib/auth/request";
import { currentUser } from "@/lib/auth/session";
import { authModeOf, getOidcState } from "@/lib/auth/settings";

export const metadata: Metadata = { title: "Sign in" };

type Search = { next?: string; error?: string; signedOut?: string };

export default async function LoginPage({ searchParams }: { searchParams: Promise<Search> }) {
  await connection();
  const { next, error, signedOut } = await searchParams;
  const state = await getOidcState();
  const settings = state.settings;
  const mode = authModeOf(state);
  const returnTo = safeReturnTo(next);
  if (mode === "enforced" && (await currentUser())) redirect(returnTo);

  return (
    <div className="login">
      <div className="login-card">
        <div className="logo login-logo">
          <VBoxLogo size={36} />
        </div>
        <h1>Sign in</h1>
        <p className="muted">Agent Sandbox in this tenant cluster.</p>

        {error && (
          <div className="alert login-message" role="alert">
            <CircleAlert size={18} strokeWidth={1.75} />
            <div>
              <strong>Sign-in failed.</strong> {error}
            </div>
          </div>
        )}
        {signedOut && !error && (
          <div className="form-result form-result-ok login-message" role="status">
            <CircleCheck size={18} strokeWidth={1.75} />
            <div>You are signed out.</div>
          </div>
        )}

        {mode === "unavailable" ? (
          <div className="alert login-message" role="alert">
            <CircleAlert size={18} strokeWidth={1.75} />
            <div>
              <strong>Sign-in is unavailable.</strong> {state.error} vBox stays locked until the settings can be read.
            </div>
          </div>
        ) : mode === "enforced" ? (
          <a className="btn btn-primary btn-block" href={`/api/auth/login?next=${encodeURIComponent(returnTo)}`}>
            <LogIn size={18} />
            Sign in with {settings.displayName}
          </a>
        ) : (
          <>
            <p className="login-off">
              {mode === "disabled-by-env"
                ? "Sign-in is switched off by VBOX_AUTH=off, so vBox is open without signing in."
                : "Single sign-on is not configured, so vBox is open without signing in."}
            </p>
            <div className="login-actions">
              <Link className="btn btn-primary" href={returnTo}>
                Continue to vBox
              </Link>
              <Link className="btn" href="/settings">
                Configure sign-in
              </Link>
            </div>
          </>
        )}
      </div>
    </div>
  );
}
