// The OpenID Connect provider configuration, edited on the Settings page, and
// whether sign-in is enforced.
//
// Two places it can live:
// - In a Kubernetes cluster: the Secret in vBox's namespace that carries the
//   annotation vbox.vcluster.com/oidc-config: "true" (VBOX_OIDC_SECRET_ANNOTATION
//   overrides the key). It is found by that annotation, not by name. The Secret is
//   the source of truth: edits made to it with kubectl show up in the UI within
//   CACHE_TTL_MS, and saving the form writes it back.
// - auth.db, outside a cluster (local development), unless
//   VBOX_OIDC_SECRET_NAMESPACE points vBox at a namespace to search.
import { readFileSync } from "node:fs";
import { getClients } from "../k8s/client";
import { getAuthStore } from "./store";

export interface OidcSettings {
  enabled: boolean;
  // Shown on the sign-in button: "Sign in with <displayName>".
  displayName: string;
  issuerUrl: string;
  clientId: string;
  // Empty for a public client, which then relies on PKCE alone.
  clientSecret: string;
  scopes: string;
  // ID token (or userinfo) claim used as the user's name in vBox.
  usernameClaim: string;
  groupsClaim: string;
  // When non-empty, only members of at least one of these groups can sign in.
  allowedGroups: string[];
  // Also end the session at the provider (RP-initiated logout) on sign-out.
  providerLogout: boolean;
}

export const DEFAULT_OIDC: OidcSettings = {
  enabled: false,
  displayName: "OpenID Connect",
  issuerUrl: "",
  clientId: "",
  clientSecret: "",
  scopes: "openid profile email",
  usernameClaim: "email",
  groupsClaim: "groups",
  allowedGroups: [],
  providerLogout: false,
};

export type SettingsSource =
  // name: the Secret found by the annotation, once one has been.
  | { kind: "secret"; namespace: string; annotation: string; name?: string }
  | { kind: "database"; file: string };

export interface OidcState {
  settings: OidcSettings;
  source: SettingsSource;
  // Opaque; the form sends it back so a save cannot silently overwrite a change
  // made elsewhere in between (the Secret's resourceVersion).
  version?: string;
  updatedAt?: string;
  updatedBy?: string;
  // Set when the settings could not be read and none were read before: whether
  // sign-in is required is unknown, so it fails closed.
  error?: string;
  // Set when a re-read failed after a good one: the last good settings stay in
  // force (enforcement never lapses), and the Settings page says so.
  staleSince?: string;
  staleReason?: string;
}

export class SettingsConflictError extends Error {}

// Identifies the provider configuration a session was issued under.
export const providerKey = (s: Pick<OidcSettings, "issuerUrl" | "clientId">) => `${s.issuerUrl} ${s.clientId}`;

// ---------- where the settings live ----------

const SA_NAMESPACE_FILE = "/var/run/secrets/kubernetes.io/serviceaccount/namespace";
export const DEFAULT_SECRET_ANNOTATION = "vbox.vcluster.com/oidc-config";

// The namespace vBox runs in: VBOX_OIDC_SECRET_NAMESPACE, else the pod's own
// (from its service account mount). Undefined outside a cluster.
function ownNamespace(): string | undefined {
  if (process.env.VBOX_OIDC_SECRET_NAMESPACE) return process.env.VBOX_OIDC_SECRET_NAMESPACE;
  try {
    return readFileSync(SA_NAMESPACE_FILE, "utf8").trim() || undefined;
  } catch {
    return undefined;
  }
}

export function settingsSource(): SettingsSource {
  const namespace = ownNamespace();
  if (namespace) {
    const annotation = process.env.VBOX_OIDC_SECRET_ANNOTATION || DEFAULT_SECRET_ANNOTATION;
    return { kind: "secret", namespace, annotation };
  }
  return { kind: "database", file: getAuthStore().file };
}

// ---------- Secret encoding: one key per field, so it can be read and edited
// with kubectl, or filled by External Secrets ----------

const ANNOTATION_UPDATED_AT = "vbox.vcluster.com/updated-at";
const ANNOTATION_UPDATED_BY = "vbox.vcluster.com/updated-by";

const bool = (v: string | undefined, fallback: boolean) =>
  v === undefined ? fallback : ["true", "yes", "1", "on"].includes(v.trim().toLowerCase());
const list = (v: string | undefined) => (v ?? "").split(/[\s,]+/).filter(Boolean);

export function fromSecretData(data: Record<string, string>): OidcSettings {
  const d = (k: string) => {
    const v = data[k];
    return v === undefined ? undefined : Buffer.from(v, "base64").toString("utf8");
  };
  const text = (k: keyof OidcSettings) => d(k)?.trim() || (DEFAULT_OIDC[k] as string);
  return {
    enabled: bool(d("enabled"), DEFAULT_OIDC.enabled),
    displayName: text("displayName"),
    issuerUrl: text("issuerUrl").replace(/\/+$/, ""),
    clientId: text("clientId"),
    clientSecret: d("clientSecret")?.trim() ?? "",
    scopes: text("scopes"),
    usernameClaim: text("usernameClaim"),
    groupsClaim: text("groupsClaim"),
    allowedGroups: list(d("allowedGroups")),
    providerLogout: bool(d("providerLogout"), DEFAULT_OIDC.providerLogout),
  };
}

export function toSecretData(s: OidcSettings): Record<string, string> {
  const strings: Record<keyof OidcSettings, string> = {
    enabled: String(s.enabled),
    displayName: s.displayName,
    issuerUrl: s.issuerUrl,
    clientId: s.clientId,
    clientSecret: s.clientSecret,
    scopes: s.scopes,
    usernameClaim: s.usernameClaim,
    groupsClaim: s.groupsClaim,
    allowedGroups: s.allowedGroups.join("\n"),
    providerLogout: String(s.providerLogout),
  };
  return Object.fromEntries(Object.entries(strings).map(([k, v]) => [k, Buffer.from(v).toString("base64")]));
}

interface SecretObject {
  metadata: { name: string; resourceVersion?: string; annotations?: Record<string, string> } & Record<string, unknown>;
  data?: Record<string, string>;
}

type SecretSource = Extract<SettingsSource, { kind: "secret" }>;

// None or several Secrets carry the annotation: vBox cannot tell which settings
// apply, so sign-in fails closed with this message.
class SecretDiscoveryError extends Error {}

// The one Secret in the namespace annotated <annotation>: "true". Kubernetes has
// no server-side filter on annotations, so this lists the namespace's Secrets and
// picks it out; RBAC therefore grants list on Secrets in vBox's own namespace.
// The list also carries the Secret's current resourceVersion, which saving uses.
async function findSecret(src: SecretSource): Promise<SecretObject> {
  const { core } = getClients();
  const res = await core.listNamespacedSecret({ namespace: src.namespace });
  const matches = (res.items as SecretObject[]).filter(
    (s) => s.metadata.annotations?.[src.annotation]?.trim().toLowerCase() === "true",
  );
  if (matches.length === 0) {
    throw new SecretDiscoveryError(
      `No Secret in namespace ${src.namespace} is annotated ${src.annotation}: "true".`,
    );
  }
  if (matches.length > 1) {
    throw new SecretDiscoveryError(
      `${matches.length} Secrets in namespace ${src.namespace} are annotated ${src.annotation}: "true" ` +
        `(${matches.map((m) => m.metadata.name).join(", ")}). Exactly one may be.`,
    );
  }
  return matches[0];
}

const statusOf = (err: unknown) => (err as { code?: number }).code;

async function readSecret(src: SecretSource): Promise<OidcState> {
  const secret = await findSecret(src);
  const annotations = secret.metadata.annotations ?? {};
  return {
    settings: fromSecretData(secret.data ?? {}),
    source: { ...src, name: secret.metadata.name },
    version: secret.metadata.resourceVersion,
    updatedAt: annotations[ANNOTATION_UPDATED_AT],
    updatedBy: annotations[ANNOTATION_UPDATED_BY],
  };
}

// PUT with the resourceVersion the form was loaded with: the API server refuses it
// with 409 when the Secret has changed since. Keys vBox does not know are kept.
async function writeSecret(
  src: SecretSource,
  s: OidcSettings,
  version: string | undefined,
  updatedBy: string | undefined,
): Promise<void> {
  const { core } = getClients();
  const current = await findSecret(src);
  if (version && current.metadata.resourceVersion !== version) throw new SettingsConflictError();
  const annotations = {
    ...(current.metadata.annotations ?? {}),
    [ANNOTATION_UPDATED_AT]: new Date().toISOString(),
    ...(updatedBy ? { [ANNOTATION_UPDATED_BY]: updatedBy } : {}),
  };
  if (!updatedBy) delete annotations[ANNOTATION_UPDATED_BY];
  try {
    await core.replaceNamespacedSecret({
      name: current.metadata.name,
      namespace: src.namespace,
      body: {
        ...current,
        metadata: { ...current.metadata, annotations },
        data: { ...(current.data ?? {}), ...toSecretData(s) },
      },
    });
  } catch (err) {
    if (statusOf(err) === 409) throw new SettingsConflictError();
    throw err;
  }
}

// ---------- cached reads ----------

// How long a read of the Secret is reused. Every request asks (the proxy checks
// sign-in on each one), so this bounds the API calls to one per interval and is
// also how long a kubectl edit takes to show up.
const CACHE_TTL_MS = 5000;

const globalForSettings = globalThis as unknown as {
  __vboxSettings?: { state: OidcState; at: number };
  // One read in flight at a time, shared by every request waiting on it.
  __vboxSettingsPending?: Promise<OidcState>;
};

function describe(err: unknown, src: SettingsSource): string {
  if (src.kind !== "secret" || err instanceof SecretDiscoveryError) return (err as Error).message;
  const code = statusOf(err);
  if (code === 403) return `The vbox service account may not list Secrets in namespace ${src.namespace}.`;
  return `The Secrets in namespace ${src.namespace} could not be read: ${(err as Error).message}`;
}

async function load(): Promise<OidcState> {
  const src = settingsSource();
  if (src.kind === "database") {
    const stored = getAuthStore().getSetting<Partial<OidcSettings>>("oidc");
    return {
      settings: { ...DEFAULT_OIDC, ...stored?.value },
      source: src,
      version: stored?.updatedAt,
      updatedAt: stored?.updatedAt,
      updatedBy: stored?.updatedBy,
    };
  }
  return readSecret(src);
}

export async function getOidcState(): Promise<OidcState> {
  const cached = globalForSettings.__vboxSettings;
  if (cached && Date.now() - cached.at < CACHE_TTL_MS) return cached.state;
  globalForSettings.__vboxSettingsPending ??= load()
    .catch((err): OidcState => {
      const src = settingsSource();
      const error = describe(err, src);
      console.error("[vbox auth]", error);
      // Keep the last good settings in force, flagged as stale; with none, report
      // the error so sign-in fails closed.
      if (cached && !cached.state.error) {
        return { ...cached.state, staleSince: cached.state.staleSince ?? new Date().toISOString(), staleReason: error };
      }
      return { settings: DEFAULT_OIDC, source: src, error };
    })
    .then((state) => {
      globalForSettings.__vboxSettings = { state, at: Date.now() };
      return state;
    })
    .finally(() => {
      globalForSettings.__vboxSettingsPending = undefined;
    });
  return globalForSettings.__vboxSettingsPending;
}

export async function getOidcSettings(): Promise<OidcSettings> {
  return (await getOidcState()).settings;
}

export async function saveOidcSettings(s: OidcSettings, version: string | undefined, updatedBy?: string): Promise<void> {
  const src = settingsSource();
  if (src.kind === "secret") {
    await writeSecret(src, s, version, updatedBy);
  } else {
    const current = getAuthStore().getSetting("oidc");
    if (version && current && current.updatedAt !== version) throw new SettingsConflictError();
    getAuthStore().setSetting("oidc", s, updatedBy);
  }
  globalForSettings.__vboxSettings = undefined;
}

// ---------- enforcement ----------

// VBOX_AUTH=off is the break-glass switch: it turns enforcement off whatever the
// settings say, for when a misconfigured provider has locked everyone out.
// "unavailable": the settings could not be read, so whether sign-in is required is
// unknown, and vBox fails closed rather than open.
export type AuthMode = "enforced" | "not-configured" | "disabled-by-env" | "unavailable";

export function authModeOf(state: OidcState): AuthMode {
  if (process.env.VBOX_AUTH === "off") return "disabled-by-env";
  if (state.error) return "unavailable";
  const s = state.settings;
  return s.enabled && s.issuerUrl && s.clientId ? "enforced" : "not-configured";
}

export async function authMode(): Promise<AuthMode> {
  return authModeOf(await getOidcState());
}
