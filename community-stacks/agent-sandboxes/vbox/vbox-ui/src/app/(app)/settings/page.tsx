import type { Metadata } from "next";
import { connection } from "next/server";
import { CircleAlert, Database, KeyRound } from "lucide-react";
import { Card, Page } from "@/components/page";
import { postLogoutUriFor, redirectUriFor } from "@/lib/auth/request";
import { currentOrigin, currentUser, requireUser } from "@/lib/auth/session";
import { authModeOf, getOidcState } from "@/lib/auth/settings";
import { dateTime } from "@/lib/format";
import { SettingsForm } from "./settings-form";

export const metadata: Metadata = { title: "Settings" };

export default async function SettingsPage() {
  await connection();
  await requireUser("/settings");
  const state = await getOidcState();
  const { clientSecret, ...settings } = state.settings;
  const { updatedAt, updatedBy, source } = state;
  const mode = authModeOf(state);
  const origin = await currentOrigin();
  const user = await currentUser();

  return (
    <Page crumbs={[{ label: "vBox" }, { label: "Settings" }]} title="Settings">
      {mode === "disabled-by-env" && (
        <div className="notice settings-notice" role="status">
          <CircleAlert size={20} strokeWidth={1.75} />
          <div>
            <strong>Sign-in is switched off by VBOX_AUTH=off.</strong> Whatever is saved here, vBox does not ask anyone
            to sign in until that variable is removed.
          </div>
        </div>
      )}
      {state.staleReason && (
        <div className="alert settings-notice" role="alert">
          <CircleAlert size={20} strokeWidth={1.75} />
          <div>
            <strong>The settings Secret cannot be read.</strong> {state.staleReason} The settings below are the last
            ones read, at {dateTime(state.staleSince)}, and stay in force until it can be read again. Saving will fail
            until then.
          </div>
        </div>
      )}
      {mode === "not-configured" && (
        <div className="notice settings-notice" role="status">
          <CircleAlert size={20} strokeWidth={1.75} />
          <div>
            <strong>Sign-in is off.</strong> Anyone who can reach vBox can see every sandbox and change these settings.
            Configure a provider and enable sign-in below.
          </div>
        </div>
      )}

      <div className="page-stack">
        <Card
          icon={<KeyRound size={22} strokeWidth={1.75} />}
          title="OpenID Connect"
          aside={
            <span className={`chip ${mode === "enforced" ? "chip-green" : "chip-gray"}`}>
              {mode === "enforced" ? "Sign-in required" : "Sign-in off"}
            </span>
          }
        >
          <SettingsForm
            initial={{ ...settings, allowedGroups: settings.allowedGroups.join("\n") }}
            hasSecret={clientSecret !== ""}
            version={state.version ?? ""}
            redirectUri={redirectUriFor(origin)}
            postLogoutUri={postLogoutUriFor(origin)}
            publicUrlFromEnv={Boolean(process.env.VBOX_PUBLIC_URL)}
            signedInAs={user?.username}
          />
          <p className="muted settings-updated with-icon">
            <Database size={14} strokeWidth={1.75} />
            {source.kind === "secret" ? (
              <span>
                Stored in the Secret <code>
                  {source.namespace}/{source.name}
                </code>
                , found by its annotation <code>{source.annotation}: &quot;true&quot;</code>. Changes made to it directly
                show up here within a few seconds.
              </span>
            ) : (
              <span>
                Stored in <code>{source.file}</code>. In a cluster, vBox keeps it in the Secret annotated{" "}
                <code>vbox.vcluster.com/oidc-config: &quot;true&quot;</code> instead.
              </span>
            )}
            {updatedAt && (
              <span>
                Last saved {dateTime(updatedAt)}
                {updatedBy ? ` by ${updatedBy}` : ""}.
              </span>
            )}
          </p>
        </Card>
      </div>
    </Page>
  );
}
