"use client";

import { useActionState, useState } from "react";
import { CircleAlert, CircleCheck, Copy, PlugZap, Save } from "lucide-react";
import { submitSettings, type SettingsState } from "./actions";

interface Values {
  enabled: boolean;
  displayName: string;
  issuerUrl: string;
  clientId: string;
  scopes: string;
  usernameClaim: string;
  groupsClaim: string;
  allowedGroups: string;
  providerLogout: boolean;
}

function CopyField({ label, value, hint }: { label: string; value: string; hint: React.ReactNode }) {
  const [copied, setCopied] = useState(false);
  return (
    <div className="field">
      <span className="field-label">{label}</span>
      <div className="copy-field">
        <code>{value}</code>
        <button
          type="button"
          className="icon-button"
          aria-label={`Copy ${label}`}
          title="Copy"
          onClick={() =>
            navigator.clipboard?.writeText(value).then(() => {
              setCopied(true);
              setTimeout(() => setCopied(false), 1500);
            })
          }
        >
          {copied ? <CircleCheck size={16} /> : <Copy size={16} />}
        </button>
      </div>
      <span className="field-hint">{hint}</span>
    </div>
  );
}

function Field({
  label,
  hint,
  children,
}: {
  label: string;
  hint?: React.ReactNode;
  children: React.ReactNode;
}) {
  return (
    <label className="field">
      <span className="field-label">{label}</span>
      {children}
      {hint && <span className="field-hint">{hint}</span>}
    </label>
  );
}

export function SettingsForm({
  initial,
  hasSecret,
  version,
  redirectUri,
  postLogoutUri,
  publicUrlFromEnv,
  signedInAs,
}: {
  initial: Values;
  hasSecret: boolean;
  version: string;
  redirectUri: string;
  postLogoutUri: string;
  publicUrlFromEnv: boolean;
  signedInAs?: string;
}) {
  // Controlled, so a failed save keeps what was typed (React resets uncontrolled
  // fields after a form action).
  const [v, setV] = useState(initial);
  const [secret, setSecret] = useState("");
  const [clearSecret, setClearSecret] = useState(false);
  const [state, action, pending] = useActionState<SettingsState, FormData>(submitSettings, {});
  const set =
    <K extends keyof Values>(k: K) =>
    (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) =>
      setV((prev) => ({ ...prev, [k]: e.target.type === "checkbox" ? (e.target as HTMLInputElement).checked : e.target.value }));

  const urlHint = publicUrlFromEnv
    ? "From VBOX_PUBLIC_URL."
    : "Derived from this request. Set VBOX_PUBLIC_URL if vBox is reached under another address.";

  return (
    <form action={action} className="settings-form">
      <input type="hidden" name="version" value={version} />
      <section className="form-section">
        <h3>Provider</h3>
        <Field
          label="Issuer URL"
          hint={
            <>
              vBox reads <code>/.well-known/openid-configuration</code> under it. For Microsoft Entra ID:{" "}
              <code>https://login.microsoftonline.com/&lt;tenant-id&gt;/v2.0</code>
            </>
          }
        >
          <input
            className="text-input"
            name="issuerUrl"
            type="url"
            value={v.issuerUrl}
            onChange={set("issuerUrl")}
            placeholder="https://idp.example.com"
            autoComplete="off"
          />
        </Field>
        <div className="field-row">
          <Field label="Client ID">
            <input
              className="text-input"
              name="clientId"
              value={v.clientId}
              onChange={set("clientId")}
              autoComplete="off"
            />
          </Field>
          <Field
            label="Client secret"
            hint={
              hasSecret
                ? "A secret is stored. Leave blank to keep it."
                : "Leave blank for a public client; PKCE is used either way."
            }
          >
            <input
              className="text-input"
              name="clientSecret"
              type="password"
              value={secret}
              onChange={(e) => setSecret(e.target.value)}
              placeholder={hasSecret ? "••••••••  (unchanged)" : ""}
              autoComplete="new-password"
              disabled={clearSecret}
            />
          </Field>
        </div>
        {hasSecret && (
          <label className="toggle">
            <input
              type="checkbox"
              name="clearSecret"
              checked={clearSecret}
              onChange={(e) => setClearSecret(e.target.checked)}
            />
            Remove the stored secret
          </label>
        )}
        <div className="field-row">
          <Field label="Scopes" hint="Space-separated. openid is always included.">
            <input className="text-input" name="scopes" value={v.scopes} onChange={set("scopes")} />
          </Field>
          <Field label="Button label" hint={`Shown as "Sign in with ${v.displayName || "OpenID Connect"}".`}>
            <input className="text-input" name="displayName" value={v.displayName} onChange={set("displayName")} />
          </Field>
        </div>
      </section>

      <section className="form-section">
        <h3>Register these with the provider</h3>
        <CopyField label="Redirect URI" value={redirectUri} hint={urlHint} />
        <CopyField
          label="Post-logout redirect URI"
          value={postLogoutUri}
          hint="Only needed with provider sign-out below."
        />
      </section>

      <section className="form-section">
        <h3>Users</h3>
        <div className="field-row">
          <Field label="Username claim" hint="Falls back to preferred_username, email, then sub.">
            <input className="text-input" name="usernameClaim" value={v.usernameClaim} onChange={set("usernameClaim")} />
          </Field>
          <Field label="Groups claim">
            <input className="text-input" name="groupsClaim" value={v.groupsClaim} onChange={set("groupsClaim")} />
          </Field>
        </div>
        <Field
          label="Allowed groups"
          hint="One per line or comma-separated. Empty lets every user the provider authenticates sign in. For Entra ID, these are group object IDs."
        >
          <textarea
            className="text-input"
            name="allowedGroups"
            rows={3}
            value={v.allowedGroups}
            onChange={set("allowedGroups")}
          />
        </Field>
        <label className="toggle">
          <input type="checkbox" name="providerLogout" checked={v.providerLogout} onChange={set("providerLogout")} />
          Also sign out of the provider when signing out of vBox
        </label>
      </section>

      <section className="form-section">
        <label className="toggle toggle-strong">
          <input type="checkbox" name="enabled" checked={v.enabled} onChange={set("enabled")} />
          Require sign-in
        </label>
        <p className="field-hint">
          {signedInAs
            ? `Signed in as ${signedInAs}. Changing the issuer or client ID signs everyone out, you included.`
            : "After saving with this on, you are sent to the provider to sign in."}
        </p>
      </section>

      {state.message && (
        <div className={state.ok ? "form-result form-result-ok" : "alert"} role="status">
          {state.ok ? <CircleCheck size={18} /> : <CircleAlert size={18} />}
          <div>
            <div>{state.message}</div>
            {state.provider && (
              <dl className="form-provider">
                <dt>Issuer</dt>
                <dd>{state.provider.issuer}</dd>
                <dt>Authorization</dt>
                <dd>{state.provider.authorization}</dd>
                <dt>Token</dt>
                <dd>{state.provider.token}</dd>
                <dt>End session</dt>
                <dd>{state.provider.endSession ?? "Not offered"}</dd>
                <dt>PKCE (S256)</dt>
                <dd>{state.provider.pkce ? "Advertised" : "Not advertised; vBox sends it anyway"}</dd>
              </dl>
            )}
          </div>
        </div>
      )}

      <div className="form-actions">
        <button type="submit" name="intent" value="test" className="btn" disabled={pending || !v.issuerUrl}>
          <PlugZap size={16} />
          Test connection
        </button>
        <button type="submit" name="intent" value="save" className="btn btn-primary" disabled={pending}>
          <Save size={16} />
          {pending ? "Saving..." : "Save"}
        </button>
      </div>
    </form>
  );
}
